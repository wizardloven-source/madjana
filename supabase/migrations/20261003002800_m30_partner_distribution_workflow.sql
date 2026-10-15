-- ============================================================================
-- M30 (W7.3): store + approve a profit distribution
-- ============================================================================
-- WHY
--   M22 shipped the ledger (profit_distributions + profit_distribution_details)
--   and M24 shipped the read-only PREVIEW (calculate_profit_distribution).
--   There was no server path to *store* the engine's result and none to
--   *approve* it. M23-M29 leave the tables writable by hand (INSERT/UPDATE via
--   RLS), but nothing keeps the stored numbers equal to the engine, and nothing
--   stops a farm manager from self-approving (the manager UPDATE policy allows
--   it). This migration closes both gaps with two SECURITY DEFINER functions
--   and one status guard trigger.
--
-- WHAT
--   1) guard_profit_distribution_status() + trigger
--        * BEFORE INSERT OR UPDATE OF status, approved_by, approved_at
--        * INSERT  : a non-admin may only create a `draft` (and with no approver
--                    fields set).
--        * UPDATE  : only a system_admin may touch status/approved_by/
--                    approved_at, and only along the legal ladder
--                    draft -> calculated -> approved -> distributed
--                    (draft/calculated/approved may also -> cancelled).
--        * This is the item-4 requirement: the manager UPDATE policy stays, but
--          the trigger is the second lock that makes status change admin-only.
--          (Chosen over a column-level GRANT because it also enforces the
--          ladder transitions, which a grant cannot.)
--   2) create_profit_distribution(...) -> uuid
--        * gate: is_system_admin() OR user_manages_farm(p_farm_id)
--        * calls calculate_profit_distribution() for the per-partner lines and
--          stores the header as `draft` + the lines as `pending`,
--          atomically (one function = one transaction).
--        * writes one partner_audit('distribution_created') row PER LINE.
--   3) approve_profit_distribution(p_distribution_id) -> void
--        * gate: is_system_admin() ONLY (a manager cannot self-approve)
--        * draft -> approved, stamps approved_by = auth.uid(), approved_at = now()
--        * writes partner_audit('distribution_approved') (header-level).
--
-- SOURCE OF THE NUMBERS
--   The header totals are re-summed from the same source tables and with the
--   same filters as calculate_profit_distribution (M29v2): revenue.amount +
--   payments.amount_paid (flock scope via the dispatch) - expenses.amount. The
--   per-partner lines come straight from calculate_profit_distribution(), so a
--   stored line can never drift from the preview of the same period.
--
--   !! KNOWN GAP (flagged, not fixed here) !!
--   calculate_profit_distribution() prices every share on NET profit
--   (revenue - expenses) and ignores the reserve. So when p_reserve_amount > 0
--   the header's distributable_profit (= net - reserve) is smaller than the sum
--   of the stored line net_amounts (= net). Keep the reserve at 0 until the
--   engine itself takes the reserve into account -- otherwise the ledger
--   header and its lines disagree on purpose.
--
--   !! NEGATIVE NET PROFIT !!
--   A period whose expenses exceed revenue cannot be distributed: the line
--   profit_share CHECK (>= 0) would reject the negative shares. The function
--   therefore raises NEGATIVE_NET_PROFIT up front instead of failing deep in a
--   CHECK with a cryptic message.
--
-- AUDIT WRITER NOTE
--   partner_audit is append-only and has no client write policy. M23 documented
--   record_partner_audit() as "the only writer" because it is admin-gated --
--   but create_profit_distribution() may be called by a farm MANAGER, so routing
--   it through the admin-gated function would fail. Both functions here are
--   SECURITY DEFINER and therefore legitimate server-side writers (the case
--   M23's own comment already anticipates: "server-side writers ... and, from
--   M24, the workflow functions"). They insert into partner_audit directly.
--
-- IDEMPOTENT. RE-RUN SAFE. NO EXISTING TABLE, POLICY, GRANT OR ROW IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) status guard ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_profit_distribution_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m30guard$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- A non-admin may only ever create a draft, and may not pre-stamp the
        -- approver fields. The create_profit_distribution() function inserts
        -- exactly this shape, so managers keep working.
        IF NOT public.is_system_admin()
           AND (NEW.status <> 'draft'
                OR NEW.approved_by IS NOT NULL
                OR NEW.approved_at IS NOT NULL) THEN
            RAISE EXCEPTION
                'AUTHORIZATION_DENIED: only system_admin may create a distribution that is not a draft';
        END IF;
        RETURN NEW;
    END IF;

    -- UPDATE (the trigger fires on status/approved_by/approved_at)
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT public.is_system_admin() THEN
            RAISE EXCEPTION
                'AUTHORIZATION_DENIED: only system_admin may change a distribution status';
        END IF;
        IF NOT (
               (OLD.status = 'draft'      AND NEW.status IN ('calculated', 'approved', 'cancelled'))
            OR (OLD.status = 'calculated' AND NEW.status IN ('approved', 'cancelled'))
            OR (OLD.status = 'approved'   AND NEW.status IN ('distributed', 'cancelled'))
        ) THEN
            RAISE EXCEPTION 'INVALID_STATUS_TRANSITION: % -> %', OLD.status, NEW.status;
        END IF;
    END IF;

    IF NOT public.is_system_admin()
       AND (NEW.approved_by IS DISTINCT FROM OLD.approved_by
            OR NEW.approved_at IS DISTINCT FROM OLD.approved_at) THEN
        RAISE EXCEPTION
            'AUTHORIZATION_DENIED: only system_admin may set the approver fields';
    END IF;

    RETURN NEW;
END;
$m30guard$;

DROP TRIGGER IF EXISTS trg_profit_distributions_guard ON public.profit_distributions;
CREATE TRIGGER trg_profit_distributions_guard
    BEFORE INSERT OR UPDATE OF status, approved_by, approved_at
    ON public.profit_distributions
    FOR EACH ROW EXECUTE FUNCTION public.guard_profit_distribution_status();

-- ── 2) create_profit_distribution ────────────────────────────────────────────
-- Parameter order note: PostgreSQL requires every parameter after the first
-- DEFAULTed one to also carry a DEFAULT, so the two period bounds sit before
-- p_flock_id. The call to calculate_profit_distribution(p_farm_id,
-- p_period_start, p_period_end, p_flock_id) therefore stays positional-identical.
CREATE OR REPLACE FUNCTION public.create_profit_distribution(
    p_farm_id        uuid,
    p_period_start   date,
    p_period_end     date,
    p_flock_id       uuid    DEFAULT NULL,
    p_reserve_amount numeric DEFAULT 0,
    p_label          text    DEFAULT NULL,
    p_notes          text    DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m30create$
DECLARE
    v_actor      uuid := auth.uid();
    v_flock_farm uuid;
    v_rev        numeric(16,8);
    v_exp        numeric(16,8);
    v_net        numeric(16,8);
    v_dist       uuid;
    v_line       record;
    v_pct        numeric(9,4);
    v_shares     numeric(18,4);
    v_salary     numeric(16,8);
    v_sal_period text;
BEGIN
    IF p_farm_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_FARM: farm id is required';
    END IF;
    IF p_period_start IS NULL OR p_period_end IS NULL THEN
        RAISE EXCEPTION 'INVALID_PERIOD: period start and end are required';
    END IF;
    IF p_period_end < p_period_start THEN
        RAISE EXCEPTION 'INVALID_PERIOD: period_end must be >= period_start';
    END IF;
    IF p_reserve_amount IS NULL OR p_reserve_amount < 0 THEN
        RAISE EXCEPTION 'INVALID_RESERVE: reserve_amount must be >= 0';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.farms WHERE id = p_farm_id) THEN
        RAISE EXCEPTION 'FARM_NOT_FOUND: %', p_farm_id;
    END IF;
    IF p_flock_id IS NOT NULL THEN
        SELECT f.farm_id INTO v_flock_farm FROM public.flocks f WHERE f.id = p_flock_id;
        IF v_flock_farm IS NULL THEN
            RAISE EXCEPTION 'FLOCK_NOT_FOUND: %', p_flock_id;
        END IF;
        IF v_flock_farm <> p_farm_id THEN
            RAISE EXCEPTION 'FLOCK_FARM_MISMATCH: flock % does not belong to farm %',
                p_flock_id, p_farm_id;
        END IF;
    END IF;
    IF NOT (public.is_system_admin() OR public.user_manages_farm(p_farm_id)) THEN
        RAISE EXCEPTION
            'AUTHORIZATION_DENIED: cannot create a distribution for farm %', p_farm_id;
    END IF;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'NO_SESSION: create_profit_distribution requires an authenticated caller';
    END IF;

    -- Totals: the SAME source and filters as calculate_profit_distribution (M29v2).
    SELECT COALESCE(SUM(sr.amount), 0)
      INTO v_rev
      FROM public.revenue sr
     WHERE sr.farm_id = p_farm_id
       AND sr.deleted_at IS NULL
       AND sr.date BETWEEN p_period_start AND p_period_end
       AND (p_flock_id IS NULL OR sr.flock_id = p_flock_id);

    v_rev := v_rev + COALESCE((
        SELECT SUM(pay.amount_paid)
          FROM public.payments pay
         WHERE pay.farm_id = p_farm_id
           AND pay.deleted_at IS NULL
           AND pay.date BETWEEN p_period_start AND p_period_end
           AND (p_flock_id IS NULL
                OR EXISTS (SELECT 1 FROM public.egg_dispatch d
                            WHERE d.id = pay.dispatch_id
                              AND d.flock_id = p_flock_id))
    ), 0);

    SELECT COALESCE(SUM(se.amount), 0)
      INTO v_exp
      FROM public.expenses se
     WHERE se.farm_id = p_farm_id
       AND se.deleted_at IS NULL
       AND se.date BETWEEN p_period_start AND p_period_end
       AND (p_flock_id IS NULL OR se.flock_id = p_flock_id);

    v_net := v_rev - v_exp;
    IF v_net < 0 THEN
        RAISE EXCEPTION
            'NEGATIVE_NET_PROFIT: period net profit is %; cannot distribute a loss', v_net;
    END IF;

    -- Header. status/draft + the arithmetic is left to the M22 CHECKs, which
    -- this insert satisfies by construction. A duplicate (farm, flock, period)
    -- hits profit_distributions_period_unique and is reported as a domain error.
    BEGIN
        INSERT INTO public.profit_distributions (
            farm_id, flock_id, period_start, period_end, label, status,
            total_revenue, total_expenses, net_profit, reserve_amount,
            distributable_profit, currency, calculated_at, created_by, notes
        ) VALUES (
            p_farm_id, p_flock_id, p_period_start, p_period_end, p_label, 'draft',
            v_rev, v_exp, v_net, p_reserve_amount,
            v_net - p_reserve_amount, 'dollar', now(), v_actor, p_notes
        )
        RETURNING id INTO v_dist;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION
            'DISTRIBUTION_EXISTS: a distribution already exists for farm % / flock % / % .. %',
            p_farm_id, p_flock_id, p_period_start, p_period_end;
    END;

    -- Lines: straight from the engine. Split each amount into profit_share vs
    -- salary_total by reading the partner's salary, i.e. exactly the salary
    -- component calculate_profit_distribution() added to the amount.
    FOR v_line IN
        SELECT * FROM public.calculate_profit_distribution(
            p_farm_id, p_period_start, p_period_end, p_flock_id)
    LOOP
        SELECT p.percentage, p.shares, p.salary_amount, p.salary_period
          INTO v_pct, v_shares, v_salary, v_sal_period
          FROM public.partners p
         WHERE p.id = v_line.partner_id;

        IF NOT (v_line.share_type IN ('salary', 'mixed') AND v_salary IS NOT NULL) THEN
            v_salary := 0;
        END IF;

        INSERT INTO public.profit_distribution_details (
            distribution_id, farm_id, partner_id, share_model,
            percentage, shares, salary_amount, salary_period,
            profit_share, salary_total, deductions, net_amount, currency, status
        ) VALUES (
            v_dist, p_farm_id, v_line.partner_id, v_line.share_type,
            v_pct, v_shares, NULLIF(v_salary, 0)::numeric(16,8), v_sal_period,
            v_line.amount - COALESCE(v_salary, 0), COALESCE(v_salary, 0), 0,
            v_line.amount, 'dollar', 'pending'
        );

        -- One audit row PER LINE (the user's chosen, most granular trail).
        INSERT INTO public.partner_audit (
            farm_id, partner_id, action, new_values, changed_by, notes
        ) VALUES (
            p_farm_id, v_line.partner_id, 'distribution_created',
            jsonb_build_object(
                'distribution_id', v_dist,
                'period_start', p_period_start,
                'period_end', p_period_end,
                'flock_id', p_flock_id,
                'share_model', v_line.share_type,
                'net_amount', v_line.amount),
            v_actor,
            'auto: create_profit_distribution'
        );
    END LOOP;

    RETURN v_dist;
END;
$m30create$;

-- ── 3) approve_profit_distribution ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.approve_profit_distribution(
    p_distribution_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m30approve$
DECLARE
    v_actor uuid := auth.uid();
    v_row   public.profit_distributions%ROWTYPE;
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: only system_admin may approve a distribution';
    END IF;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'NO_SESSION: approve_profit_distribution requires an authenticated caller';
    END IF;

    SELECT * INTO v_row FROM public.profit_distributions WHERE id = p_distribution_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DISTRIBUTION_NOT_FOUND: %', p_distribution_id;
    END IF;
    IF v_row.status <> 'draft' THEN
        RAISE EXCEPTION 'INVALID_STATUS_TRANSITION: % -> approved', v_row.status;
    END IF;

    UPDATE public.profit_distributions
       SET status      = 'approved',
           approved_by = v_actor,
           approved_at = now()
     WHERE id = p_distribution_id;

    INSERT INTO public.partner_audit (
        farm_id, partner_id, action, new_values, changed_by, notes
    ) VALUES (
        v_row.farm_id, NULL, 'distribution_approved',
        jsonb_build_object('distribution_id', p_distribution_id, 'approved_by', v_actor),
        v_actor, 'auto: approve_profit_distribution'
    );
END;
$m30approve$;

-- ── 4) grants ────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.create_profit_distribution(uuid, date, date, uuid, numeric, text, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_profit_distribution(uuid, date, date, uuid, numeric, text, text)
    TO authenticated;

REVOKE ALL ON FUNCTION public.approve_profit_distribution(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.approve_profit_distribution(uuid)
    TO authenticated;

-- trigger function: not callable by clients
REVOKE ALL ON FUNCTION public.guard_profit_distribution_status()
    FROM PUBLIC, anon, authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m30chk$
DECLARE
    v_n int;
BEGIN
    IF to_regprocedure(
        'public.create_profit_distribution(uuid,date,date,uuid,numeric,text,text)') IS NULL THEN
        RAISE EXCEPTION 'FAIL: create_profit_distribution() missing';
    END IF;
    IF to_regprocedure('public.approve_profit_distribution(uuid)') IS NULL THEN
        RAISE EXCEPTION 'FAIL: approve_profit_distribution() missing';
    END IF;
    IF to_regprocedure('public.guard_profit_distribution_status()') IS NULL THEN
        RAISE EXCEPTION 'FAIL: guard_profit_distribution_status() missing';
    END IF;

    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE tgname = 'trg_profit_distributions_guard' AND NOT tgisinternal;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: guard trigger not attached (found %)', v_n;
    END IF;

    IF has_function_privilege('anon',
        'public.create_profit_distribution(uuid,date,date,uuid,numeric,text,text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: anon can execute create_profit_distribution()';
    END IF;
    IF has_function_privilege('anon',
        'public.approve_profit_distribution(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: anon can execute approve_profit_distribution()';
    END IF;
    IF NOT has_function_privilege('authenticated',
        'public.create_profit_distribution(uuid,date,date,uuid,numeric,text,text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: authenticated cannot execute create_profit_distribution()';
    END IF;
    IF NOT has_function_privilege('authenticated',
        'public.approve_profit_distribution(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: authenticated cannot execute approve_profit_distribution()';
    END IF;
END;
$m30chk$;
