-- ============================================================================
-- M29-v2 (W6): drop MIXED_CURRENCY from the partner profit functions
-- ============================================================================
-- WHY
--   The currency rule for this project: amounts are ALWAYS stored in USD.
--       amount        -> the value, already in USD
--       currency      -> metadata; how the figure was handed over
--                        ('dollar' | 'lira'), never a unit to convert from
--       exchange_rate -> the FX rate frozen at entry time, never read here
--   Because every amount already shares one unit (USD), a row whose `currency`
--   is 'lira' is not a unit conflict with a row whose `currency` is 'dollar'.
--   M29 still raised MIXED_CURRENCY when the revenue / expenses rows spanned
--   two currencies; that guard is wrong under this rule and has produced false
--   failures on real books (e.g. an expense entered in lira next to a dollar
--   expense). M29-v2 removes it.
--
-- WHAT CHANGES
--   Only the two read/preview functions, and only the currency guard:
--       public.partner_net_profit(uuid, date, date, uuid)
--       public.calculate_profit_distribution(uuid, date, date, uuid)
--   - remove the MIXED_CURRENCY check on expenses
--   - remove the MIXED_CURRENCY check on revenue
--   - keep a bare SUM(amount) on each
--   Signatures, share math, authorization, the withdrawal engine and RLS are
--   untouched. The M29 revenue basis (payments.amount_paid + revenue.amount)
--   stays exactly as it is.
--
-- NOTE
--   This is a founder decision. Do not re-add MIXED_CURRENCY. No user data is
--   modified and expenses.currency is never rewritten.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) partner_net_profit (bare SUM(amount); no MIXED_CURRENCY) ─────────────
CREATE OR REPLACE FUNCTION public.partner_net_profit(
    p_partner_id   uuid,
    p_period_start date,
    p_period_end   date,
    p_flock_id     uuid DEFAULT NULL
) RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m29v2np$
DECLARE
    v_partner  public.partners%ROWTYPE;
    v_farm_id  uuid;
    v_rev      numeric(16,8);
    v_exp      numeric(16,8);
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

    -- amounts are already USD, so currency is metadata and never a conflict.
    SELECT COALESCE(SUM(r.amount), 0)
      INTO v_rev
      FROM public.revenue r
     WHERE r.deleted_at IS NULL
       AND r.date BETWEEN p_period_start AND p_period_end
       AND (p_flock_id IS NULL OR r.flock_id = p_flock_id);

    -- M29: cash collected is income too. amount_paid is ALREADY USD; its
    -- currency column is metadata, so it is never converted here.
    v_rev := v_rev + COALESCE((
        SELECT SUM(pay.amount_paid)
          FROM public.payments pay
         WHERE pay.deleted_at IS NULL
           AND pay.date BETWEEN p_period_start AND p_period_end
           AND (p_flock_id IS NULL
                OR EXISTS (SELECT 1 FROM public.egg_dispatch d
                            WHERE d.id = pay.dispatch_id
                              AND d.flock_id = p_flock_id))
    ), 0);

    SELECT COALESCE(SUM(e.amount), 0)
      INTO v_exp
      FROM public.expenses e
     WHERE e.deleted_at IS NULL
       AND e.date BETWEEN p_period_start AND p_period_end
       AND (p_flock_id IS NULL OR e.flock_id = p_flock_id);

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
$m29v2np$;

-- ── 2) calculate_profit_distribution (bare SUM(amount); no MIXED_CURRENCY) ──
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
AS $m29v2calc$
DECLARE
    v_flock_farm uuid;
    v_rev        numeric(16,8);
    v_exp        numeric(16,8);
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

    -- amounts are already USD, so currency is metadata and never a conflict.
    SELECT COALESCE(SUM(sr.amount), 0)
      INTO v_rev
      FROM public.revenue sr
     WHERE sr.farm_id = p_farm_id
       AND sr.deleted_at IS NULL
       AND sr.date BETWEEN p_period_start AND p_period_end
       AND (p_flock_id IS NULL OR sr.flock_id = p_flock_id);

    -- M29: add the farm's cash collections. amount_paid is USD; currency is
    -- metadata only; flock scope comes from the payment's dispatch.
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
$m29v2calc$;

-- ── 3) grants (unchanged; re-asserted so a bare re-run is safe) ──────────────
REVOKE ALL ON FUNCTION public.partner_net_profit(uuid, date, date, uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.partner_net_profit(uuid, date, date, uuid)
    TO authenticated;

REVOKE ALL ON FUNCTION public.calculate_profit_distribution(uuid, date, date, uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_profit_distribution(uuid, date, date, uuid)
    TO authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m29v2chk$
DECLARE
    v_np   text;
    v_calc text;
BEGIN
    IF to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)') IS NULL THEN
        RAISE EXCEPTION 'FAIL: partner_net_profit is missing';
    END IF;
    IF to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)') IS NULL THEN
        RAISE EXCEPTION 'FAIL: calculate_profit_distribution is missing';
    END IF;

    v_np   := pg_get_functiondef(to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'));
    v_calc := pg_get_functiondef(to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)'));

    -- the M29 fix must still be present: both functions read payments.amount_paid
    IF position('amount_paid' IN v_np) = 0 OR position('payments' IN v_np) = 0 THEN
        RAISE EXCEPTION 'FAIL: partner_net_profit no longer sums payments.amount_paid';
    END IF;
    IF position('amount_paid' IN v_calc) = 0 OR position('payments' IN v_calc) = 0 THEN
        RAISE EXCEPTION 'FAIL: calculate_profit_distribution no longer sums payments.amount_paid';
    END IF;

    -- the currency guard must be gone from both bodies
    IF position('MIXED_CURRENCY' IN v_np) > 0 OR position('MIXED_CURRENCY' IN v_calc) > 0 THEN
        RAISE EXCEPTION 'FAIL: M29-v2 still raises MIXED_CURRENCY';
    END IF;

    -- no currency conversion may have crept in
    IF position('exchange_rate' IN v_np) > 0 OR position('exchange_rate' IN v_calc) > 0 THEN
        RAISE EXCEPTION 'FAIL: M29-v2 reads exchange_rate; money is already USD';
    END IF;

    -- still SECURITY DEFINER with a pinned search_path
    IF NOT (SELECT prosecdef FROM pg_proc
             WHERE oid = to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'))
       OR NOT (SELECT prosecdef FROM pg_proc
                WHERE oid = to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)')) THEN
        RAISE EXCEPTION 'FAIL: an M29-v2 function is no longer SECURITY DEFINER';
    END IF;
    IF NOT (SELECT EXISTS (SELECT 1 FROM unnest(proconfig) c WHERE c LIKE 'search_path=%')
              FROM pg_proc WHERE oid = to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'))
       OR NOT (SELECT EXISTS (SELECT 1 FROM unnest(proconfig) c WHERE c LIKE 'search_path=%')
                 FROM pg_proc WHERE oid = to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)')) THEN
        RAISE EXCEPTION 'FAIL: an M29-v2 function lost its pinned search_path';
    END IF;

    RAISE NOTICE 'OK: M29-v2 verified - MIXED_CURRENCY removed; amounts are USD, currency is metadata';
END;
$m29v2chk$;
