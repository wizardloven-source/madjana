-- ============================================================================
-- M24 (W6): partner workflow functions
-- ============================================================================
-- WHY
--   M21 gave us partners + user_roles, M22 the profit ledger, M23 the
--   withdrawal/audit tables. M24 is the engine that reads them:
--
--     partner_net_profit             -- a partner's profit for a period
--     partner_pending_withdrawal     -- their cash still in flight
--     partner_summary                -- one row: name / model / profit / flows
--     approve_withdrawal             -- pending -> approved (manager/admin)
--     calculate_profit_distribution  -- preview a period's per-partner split
--
--   All five are SECURITY DEFINER with a pinned search_path, so they read the
--   ledger regardless of the caller's row visibility; the caller is gated by
--   is_system_admin() / user_manages_farm() / the partner's own user_id inside
--   each function. EXECUTE is granted to authenticated (never anon/PUBLIC).
--
-- SPEC ADAPTATIONS (the spec was written before M21/M22 were final)
--   The user's M24 spec assumed columns the shipped schema does not have. Each
--   deviation is deliberate and listed here so it is never mistaken for a bug:
--   * partners has NO farm_id and NO effective_share / salary_model columns.
--     A partner is GLOBAL (M21 deferred per-farm shares). The share value is
--     derived from share_model:
--         percentage -> percentage | shares -> shares
--         salary     -> salary_amount | mixed -> COALESCE(percentage, shares,
--                                                   salary_amount)
--     and "has a salary" == share_model IN ('salary','mixed') AND salary_amount
--     IS NOT NULL.
--   * the period arguments are HONOURED: revenue / expenses are filtered by
--     date BETWEEN p_period_start AND p_period_end (inclusive).
--   * share math is per model, not a blanket net*share/100:
--         percentage : net * percentage / 100
--         shares     : net * shares / SUM(shares of active partners with shares)
--         salary     : 0 (% profit), then salary_amount added
--         mixed      : percentage if set, else shares-normalised, then salary
--     A percentage pool and a shares pool each spread the whole net
--     independently; mixing both models in one farm double-counts. That is
--     inherent to the spec and is why calculate() raises when percentages
--     exceed 100.
--   * when p_flock_id IS NULL the "farm" is undefined (no farm argument and no
--     partners.farm_id), so partner_net_profit aggregates across ALL farms.
--   * calculate_profit_distribution RETURNS TABLE only: it previews, it does
--     NOT write profit_distributions/details. M22's header guessed it would
--     write; the spec's signature wins.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) partner_net_profit ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.partner_net_profit(
    p_partner_id   uuid,
    p_period_start date,
    p_period_end   date,
    p_flock_id     uuid DEFAULT NULL
) RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m24np$
DECLARE
    v_partner  public.partners%ROWTYPE;
    v_farm_id  uuid;
    v_rev      numeric(16,8);
    v_exp      numeric(16,8);
    v_cur      integer;
    v_net      numeric(16,8);
    v_total_sh numeric(18,4);
    v_amount   numeric(16,8);
BEGIN
    IF p_period_start IS NULL OR p_period_end IS NULL THEN
        RAISE EXCEPTION 'INVALID_PERIOD: period start and end are required';
    END IF;
    IF p_period_end < p_period_start THEN
        RAISE EXCEPTION 'INVALID_PERIOD: % precedes %', p_period_end, p_period_start;
    END IF;

    SELECT * INTO v_partner FROM public.partners WHERE id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PARTNER_NOT_FOUND: %', p_partner_id;
    END IF;

    IF p_flock_id IS NOT NULL THEN
        SELECT f.farm_id INTO v_farm_id FROM public.flocks f WHERE f.id = p_flock_id;
        IF v_farm_id IS NULL THEN
            RAISE EXCEPTION 'FLOCK_NOT_FOUND: %', p_flock_id;
        END IF;
    END IF;

    IF NOT (public.is_system_admin()
            OR v_partner.user_id = auth.uid()
            OR (v_farm_id IS NOT NULL AND public.user_manages_farm(v_farm_id))) THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: partner % is not visible to the caller',
            p_partner_id;
    END IF;

    SELECT COALESCE(SUM(r.amount), 0), COUNT(DISTINCT r.currency)
      INTO v_rev, v_cur
      FROM public.revenue r
     WHERE r.deleted_at IS NULL
       AND r.date BETWEEN p_period_start AND p_period_end
       AND (p_flock_id IS NULL OR r.flock_id = p_flock_id);
    IF v_cur > 1 THEN
        RAISE EXCEPTION 'MIXED_CURRENCY: revenue spans more than one currency';
    END IF;

    SELECT COALESCE(SUM(e.amount), 0), COUNT(DISTINCT e.currency)
      INTO v_exp, v_cur
      FROM public.expenses e
     WHERE e.deleted_at IS NULL
       AND e.date BETWEEN p_period_start AND p_period_end
       AND (p_flock_id IS NULL OR e.flock_id = p_flock_id);
    IF v_cur > 1 THEN
        RAISE EXCEPTION 'MIXED_CURRENCY: expenses span more than one currency';
    END IF;

    v_net := v_rev - v_exp;

    IF v_partner.share_model = 'percentage' THEN
        v_amount := v_net * COALESCE(v_partner.percentage, 0) / 100;
    ELSIF v_partner.share_model = 'shares' THEN
        SELECT COALESCE(SUM(p.shares), 0) INTO v_total_sh
          FROM public.partners p
         WHERE p.status = 'active' AND p.deleted_at IS NULL
           AND p.shares IS NOT NULL;
        v_amount := CASE WHEN v_total_sh > 0
                         THEN v_net * COALESCE(v_partner.shares, 0) / v_total_sh
                         ELSE 0 END;
    ELSIF v_partner.share_model = 'salary' THEN
        v_amount := 0;
    ELSE  -- mixed
        IF v_partner.percentage IS NOT NULL THEN
            v_amount := v_net * v_partner.percentage / 100;
        ELSIF v_partner.shares IS NOT NULL THEN
            SELECT COALESCE(SUM(p.shares), 0) INTO v_total_sh
              FROM public.partners p
             WHERE p.status = 'active' AND p.deleted_at IS NULL
               AND p.shares IS NOT NULL;
            v_amount := CASE WHEN v_total_sh > 0
                             THEN v_net * v_partner.shares / v_total_sh
                             ELSE 0 END;
        ELSE
            v_amount := 0;
        END IF;
    END IF;

    IF v_partner.share_model IN ('salary', 'mixed')
       AND v_partner.salary_amount IS NOT NULL THEN
        v_amount := v_amount + v_partner.salary_amount;
    END IF;

    RETURN COALESCE(v_amount, 0);
END;
$m24np$;

-- ── 2) partner_pending_withdrawal ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.partner_pending_withdrawal(
    p_partner_id uuid
) RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m24pw$
DECLARE
    v_partner public.partners%ROWTYPE;
    v_sum     numeric(16,8);
BEGIN
    SELECT * INTO v_partner FROM public.partners WHERE id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PARTNER_NOT_FOUND: %', p_partner_id;
    END IF;

    IF NOT (public.is_system_admin()
            OR v_partner.user_id = auth.uid()
            OR EXISTS (SELECT 1 FROM public.partner_withdrawals w
                        WHERE w.partner_id = p_partner_id
                          AND w.deleted_at IS NULL
                          AND public.user_manages_farm(w.farm_id))) THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: withdrawals of partner % are not visible',
            p_partner_id;
    END IF;

    SELECT COALESCE(SUM(w.amount), 0) INTO v_sum
      FROM public.partner_withdrawals w
     WHERE w.partner_id = p_partner_id
       AND w.deleted_at IS NULL
       AND w.status IN ('pending', 'approved');

    RETURN v_sum;
END;
$m24pw$;

-- ── 3) partner_summary ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.partner_summary(
    p_partner_id uuid
) RETURNS TABLE(
    name        text,
    share_model text,
    share_value numeric,
    net_profit  numeric,
    pending     numeric,
    paid        numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m24sum$
DECLARE
    v_partner     public.partners%ROWTYPE;
    v_share_value numeric(16,8);
    v_net         numeric(16,8);
    v_pend        numeric(16,8);
    v_paid        numeric(16,8);
BEGIN
    SELECT * INTO v_partner FROM public.partners WHERE id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PARTNER_NOT_FOUND: %', p_partner_id;
    END IF;

    IF NOT (public.is_system_admin()
            OR v_partner.user_id = auth.uid()) THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: partner % is not visible to the caller',
            p_partner_id;
    END IF;

    v_share_value := CASE v_partner.share_model
        WHEN 'percentage' THEN v_partner.percentage
        WHEN 'shares'     THEN v_partner.shares
        WHEN 'salary'     THEN v_partner.salary_amount
        WHEN 'mixed'      THEN COALESCE(v_partner.percentage, v_partner.shares,
                                        v_partner.salary_amount)
        ELSE NULL
    END;

    v_net := public.partner_net_profit(
                 p_partner_id,
                 date_trunc('year', CURRENT_DATE)::date,
                 CURRENT_DATE,
                 NULL);

    SELECT COALESCE(SUM(w.amount), 0) INTO v_pend
      FROM public.partner_withdrawals w
     WHERE w.partner_id = p_partner_id
       AND w.deleted_at IS NULL
       AND w.status IN ('pending', 'approved');

    SELECT COALESCE(SUM(w.amount), 0) INTO v_paid
      FROM public.partner_withdrawals w
     WHERE w.partner_id = p_partner_id
       AND w.deleted_at IS NULL
       AND w.status = 'paid';

    RETURN QUERY
        SELECT v_partner.name, v_partner.share_model,
               v_share_value, v_net, v_pend, v_paid;
END;
$m24sum$;

-- ── 4) approve_withdrawal ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.approve_withdrawal(
    p_withdrawal_id uuid,
    p_approver_id   uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m24app$
DECLARE
    v_w    public.partner_withdrawals%ROWTYPE;
    v_rows integer;
BEGIN
    SELECT * INTO v_w
      FROM public.partner_withdrawals
     WHERE id = p_withdrawal_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WITHDRAWAL_NOT_FOUND: %', p_withdrawal_id;
    END IF;

    IF NOT (public.is_system_admin() OR public.user_manages_farm(v_w.farm_id)) THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: cannot approve a withdrawal of farm %',
            v_w.farm_id;
    END IF;

    IF v_w.status <> 'pending' THEN
        RAISE EXCEPTION 'INVALID_STATUS_TRANSITION: % -> approved', v_w.status;
    END IF;

    UPDATE public.partner_withdrawals
       SET status      = 'approved',
           reviewed_by = p_approver_id,
           reviewed_at = now(),
           updated_at  = now()
     WHERE id = p_withdrawal_id
       AND status = 'pending'
       AND deleted_at IS NULL;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
        RAISE EXCEPTION 'INVALID_STATUS_TRANSITION: withdrawal % is no longer pending',
            p_withdrawal_id;
    END IF;

    RETURN;
END;
$m24app$;

-- ── 5) calculate_profit_distribution ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.calculate_profit_distribution(
    p_farm_id      uuid,
    p_period_start date,
    p_period_end   date,
    p_flock_id     uuid DEFAULT NULL
) RETURNS TABLE(
    partner_id  uuid,
    share_type  text,
    share_value numeric,
    amount      numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m24calc$
DECLARE
    v_flock_farm uuid;
    v_rev        numeric(16,8);
    v_exp        numeric(16,8);
    v_cur        integer;
    v_net        numeric(16,8);
    v_pct        numeric(9,4);
    v_total_sh   numeric(18,4);
    r            record;
BEGIN
    IF p_farm_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_FARM: farm id is required';
    END IF;
    IF p_period_start IS NULL OR p_period_end IS NULL THEN
        RAISE EXCEPTION 'INVALID_PERIOD: period start and end are required';
    END IF;
    IF p_period_end < p_period_start THEN
        RAISE EXCEPTION 'INVALID_PERIOD: % precedes %', p_period_end, p_period_start;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.farms f WHERE f.id = p_farm_id) THEN
        RAISE EXCEPTION 'FARM_NOT_FOUND: %', p_farm_id;
    END IF;

    IF p_flock_id IS NOT NULL THEN
        SELECT f.farm_id INTO v_flock_farm
          FROM public.flocks f WHERE f.id = p_flock_id;
        IF v_flock_farm IS NULL THEN
            RAISE EXCEPTION 'FLOCK_NOT_FOUND: %', p_flock_id;
        END IF;
        IF v_flock_farm <> p_farm_id THEN
            RAISE EXCEPTION 'FLOCK_FARM_MISMATCH: flock % does not belong to farm %',
                p_flock_id, p_farm_id;
        END IF;
    END IF;

    IF NOT (public.is_system_admin() OR public.user_manages_farm(p_farm_id)) THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: cannot calculate the distribution for farm %',
            p_farm_id;
    END IF;

    SELECT COALESCE(SUM(sr.amount), 0), COUNT(DISTINCT sr.currency)
      INTO v_rev, v_cur
      FROM public.revenue sr
     WHERE sr.farm_id = p_farm_id
       AND sr.deleted_at IS NULL
       AND sr.date BETWEEN p_period_start AND p_period_end
       AND (p_flock_id IS NULL OR sr.flock_id = p_flock_id);
    IF v_cur > 1 THEN
        RAISE EXCEPTION 'MIXED_CURRENCY: revenue spans more than one currency';
    END IF;

    SELECT COALESCE(SUM(se.amount), 0), COUNT(DISTINCT se.currency)
      INTO v_exp, v_cur
      FROM public.expenses se
     WHERE se.farm_id = p_farm_id
       AND se.deleted_at IS NULL
       AND se.date BETWEEN p_period_start AND p_period_end
       AND (p_flock_id IS NULL OR se.flock_id = p_flock_id);
    IF v_cur > 1 THEN
        RAISE EXCEPTION 'MIXED_CURRENCY: expenses span more than one currency';
    END IF;

    SELECT COALESCE(SUM(p.percentage), 0) INTO v_pct
      FROM public.partners p
     WHERE p.status = 'active' AND p.deleted_at IS NULL
       AND p.percentage IS NOT NULL;
    IF v_pct > 100 THEN
        RAISE EXCEPTION 'INVALID_PERCENTAGES: total partner percentage is % (max 100)', v_pct;
    END IF;

    v_net := v_rev - v_exp;

    SELECT COALESCE(SUM(p.shares), 0) INTO v_total_sh
      FROM public.partners p
     WHERE p.status = 'active' AND p.deleted_at IS NULL
       AND p.shares IS NOT NULL;

    FOR r IN
        SELECT p.id, p.share_model, p.percentage, p.shares, p.salary_amount
          FROM public.partners p
         WHERE p.status = 'active' AND p.deleted_at IS NULL
         ORDER BY p.name
    LOOP
        partner_id := r.id;
        share_type := r.share_model;

        IF r.share_model = 'percentage' THEN
            share_value := r.percentage;
        ELSIF r.share_model = 'shares' THEN
            share_value := r.shares;
        ELSIF r.share_model = 'salary' THEN
            share_value := r.salary_amount;
        ELSE
            share_value := COALESCE(r.percentage, r.shares, r.salary_amount);
        END IF;

        IF r.share_model = 'percentage' THEN
            amount := v_net * COALESCE(r.percentage, 0) / 100;
        ELSIF r.share_model = 'shares' THEN
            amount := CASE WHEN v_total_sh > 0
                           THEN v_net * COALESCE(r.shares, 0) / v_total_sh
                           ELSE 0 END;
        ELSIF r.share_model = 'salary' THEN
            amount := 0;
        ELSE  -- mixed
            IF r.percentage IS NOT NULL THEN
                amount := v_net * r.percentage / 100;
            ELSIF r.shares IS NOT NULL THEN
                amount := CASE WHEN v_total_sh > 0
                               THEN v_net * r.shares / v_total_sh
                               ELSE 0 END;
            ELSE
                amount := 0;
            END IF;
        END IF;

        IF r.share_model IN ('salary', 'mixed') AND r.salary_amount IS NOT NULL THEN
            amount := amount + r.salary_amount;
        END IF;

        RETURN NEXT;
    END LOOP;

    RETURN;
END;
$m24calc$;

-- ── 6) grants ────────────────────────────────────────────────────────────────
-- callable by signed-in users only; each function gates its own caller. anon
-- and PUBLIC get nothing, so EXECUTE is never granted to grantee 0.
REVOKE ALL ON FUNCTION public.partner_net_profit(uuid, date, date, uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.partner_net_profit(uuid, date, date, uuid)
    TO authenticated;

REVOKE ALL ON FUNCTION public.partner_pending_withdrawal(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.partner_pending_withdrawal(uuid)
    TO authenticated;

REVOKE ALL ON FUNCTION public.partner_summary(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.partner_summary(uuid)
    TO authenticated;

REVOKE ALL ON FUNCTION public.approve_withdrawal(uuid, uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.approve_withdrawal(uuid, uuid)
    TO authenticated;

REVOKE ALL ON FUNCTION public.calculate_profit_distribution(uuid, date, date, uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_profit_distribution(uuid, date, date, uuid)
    TO authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m24chk$
DECLARE
    v_sigs text[] := ARRAY[
        'public.partner_net_profit(uuid,date,date,uuid)',
        'public.partner_pending_withdrawal(uuid)',
        'public.partner_summary(uuid)',
        'public.approve_withdrawal(uuid,uuid)',
        'public.calculate_profit_distribution(uuid,date,date,uuid)'
    ];
    v_sig text;
    v_def boolean;
    v_cfg text[];
    v_n   int;
BEGIN
    FOREACH v_sig IN ARRAY v_sigs LOOP
        IF to_regprocedure(v_sig) IS NULL THEN
            RAISE EXCEPTION 'FAIL: function % is missing', v_sig;
        END IF;

        SELECT p.prosecdef, p.proconfig INTO v_def, v_cfg
          FROM pg_proc p
         WHERE p.oid = to_regprocedure(v_sig);

        IF NOT v_def THEN
            RAISE EXCEPTION 'FAIL: function % is not SECURITY DEFINER', v_sig;
        END IF;
        IF v_cfg IS NULL OR NOT EXISTS (
                SELECT 1 FROM unnest(v_cfg) c WHERE c LIKE 'search_path=%') THEN
            RAISE EXCEPTION 'FAIL: function % has no pinned search_path', v_sig;
        END IF;

        IF has_function_privilege('anon', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'FAIL: anon can execute %', v_sig;
        END IF;
        IF NOT has_function_privilege('authenticated', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'FAIL: authenticated cannot execute %', v_sig;
        END IF;
    END LOOP;

    -- never to PUBLIC (grantee 0)
    SELECT count(*) INTO v_n
      FROM pg_proc p
      CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE p.oid IN (to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'),
                     to_regprocedure('public.partner_pending_withdrawal(uuid)'),
                     to_regprocedure('public.partner_summary(uuid)'),
                     to_regprocedure('public.approve_withdrawal(uuid,uuid)'),
                     to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)'))
       AND a.grantee = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'FAIL: a W6-M24 function still grants EXECUTE to PUBLIC (grantee 0)';
    END IF;

    RAISE NOTICE 'OK: M24 verified - 5 partner workflow functions live, SECURITY DEFINER, grants correct';
END;
$m24chk$;
