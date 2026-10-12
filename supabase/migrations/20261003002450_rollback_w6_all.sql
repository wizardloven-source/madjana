-- ============================================================================
-- W6 CONSOLIDATED ROLLBACK — tear down the whole partnership milestone
-- ============================================================================
--  One-file inverse of every W6 forward migration, in the exact reverse order:
--      M25 (RLS + helper) -> M24 (workflow fns) -> M23 (withdrawals + audit)
--      -> M22 (distributions + details) -> M21 (partners + user_roles)
--      -> M1b (revenue.flock_id)
--
--  This is the convenience "undo all of W6 at once" file. The per-milestone
--  rollbacks (…01_rollback_*.sql) remain the canonical, individually-scoped
--  path and are what `supabase/tests/test_w6_rollback_cycles.py` exercises.
--
--  ⚠ WHAT IT DESTROYS
--    DROP TABLE removes every partner profile, dynamic role grant, profit
--    period/line, withdrawal request and the whole partner audit trail; it also
--    drops revenue.flock_id and with it every per-flock revenue attribution.
--    There is no backup inside the database. Export first:
--        SELECT * FROM partners;              SELECT * FROM user_roles;
--        SELECT * FROM profit_distributions;  SELECT * FROM profit_distribution_details;
--        SELECT * FROM partner_withdrawals;   SELECT * FROM partner_audit;
--        SELECT * FROM revenue WHERE flock_id IS NOT NULL;
--
--  SCOPE GUARD: refuses while any of those tables holds a row, or while any
--  revenue row still carries flock_id, so an accidental run cannot quietly
--  discard entered data.
--
--  IDEMPOTENT. RE-RUN SAFE. Order matters: the six tables are dropped before
--  the functions they feed triggers to, so no trigger dependency blocks the
--  DROP FUNCTION. No other schema is touched.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── scope guard ──────────────────────────────────────────────────────────────
DO $w6rb$
DECLARE
    v_tbl text;
    v_n   bigint;
BEGIN
    FOREACH v_tbl IN ARRAY ARRAY[
        'partners','user_roles','profit_distributions',
        'profit_distribution_details','partner_withdrawals','partner_audit'] LOOP
        IF to_regclass('public.' || v_tbl) IS NOT NULL THEN
            EXECUTE format('SELECT count(*) FROM public.%I', v_tbl) INTO v_n;
            IF v_n > 0 THEN
                RAISE EXCEPTION
                    'ABORT: public.% has % row(s). Dropping would destroy entered '
                    'data. Export it first, or delete the rows yourself once you '
                    'have accepted the loss.', v_tbl, v_n;
            END IF;
        END IF;
    END LOOP;

    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'revenue'
                  AND column_name = 'flock_id')
       AND EXISTS (SELECT 1 FROM public.revenue WHERE flock_id IS NOT NULL) THEN
        RAISE EXCEPTION
            'ABORT: revenue rows with flock_id exist. NULL them out first, or do '
            'not roll back.';
    END IF;

    RAISE NOTICE 'scope check passed: W6 tables empty, no flock_id attributions';
END;
$w6rb$;

-- ── 1. drop the triggers ─────────────────────────────────────────────────────
--   Triggers depend on the functions dropped in step 3, so they go first.
DROP TRIGGER IF EXISTS trg_partner_withdrawals_updated_at ON public.partner_withdrawals;
DROP TRIGGER IF EXISTS trg_partner_withdrawals_validate ON public.partner_withdrawals;
DROP TRIGGER IF EXISTS trg_partner_withdrawals_guard ON public.partner_withdrawals;
DROP TRIGGER IF EXISTS trg_partner_withdrawals_sync ON public.partner_withdrawals;
DROP TRIGGER IF EXISTS trg_partner_withdrawals_tombstone ON public.partner_withdrawals;
DROP TRIGGER IF EXISTS trg_partners_updated_at ON public.partners;
DROP TRIGGER IF EXISTS trg_user_roles_updated_at ON public.user_roles;
DROP TRIGGER IF EXISTS trg_profit_distributions_updated_at ON public.profit_distributions;
DROP TRIGGER IF EXISTS trg_pdd_updated_at ON public.profit_distribution_details;

-- ── 2. drop the policies ─────────────────────────────────────────────────────
--   Policies depend on the functions dropped in step 3 AND on each other's
--   tables (e.g. distributions_partner_read reads profit_distribution_details,
--   the *_partner_read policies read partners), so they must go before either.
--   Both the M25 names and the M21-M23 names are listed, so this file is safe
--   whether or not M25 was applied.
-- M25 names
DROP POLICY IF EXISTS partners_admin_all ON public.partners;
DROP POLICY IF EXISTS partners_self_read ON public.partners;
DROP POLICY IF EXISTS partners_manager_read ON public.partners;
DROP POLICY IF EXISTS partners_manager_write ON public.partners;
DROP POLICY IF EXISTS user_roles_admin_all ON public.user_roles;
DROP POLICY IF EXISTS user_roles_self_read ON public.user_roles;
DROP POLICY IF EXISTS user_roles_manager_read ON public.user_roles;
DROP POLICY IF EXISTS user_roles_manager_write ON public.user_roles;
DROP POLICY IF EXISTS distributions_admin_all ON public.profit_distributions;
DROP POLICY IF EXISTS distributions_manager_read ON public.profit_distributions;
DROP POLICY IF EXISTS distributions_partner_read ON public.profit_distributions;
DROP POLICY IF EXISTS distributions_manager_write ON public.profit_distributions;
DROP POLICY IF EXISTS details_admin_all ON public.profit_distribution_details;
DROP POLICY IF EXISTS details_manager_read ON public.profit_distribution_details;
DROP POLICY IF EXISTS details_partner_read ON public.profit_distribution_details;
DROP POLICY IF EXISTS details_manager_write ON public.profit_distribution_details;
DROP POLICY IF EXISTS withdrawals_admin_all ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_partner_read ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_partner_insert ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_manager_read ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_manager_update ON public.partner_withdrawals;
DROP POLICY IF EXISTS audit_admin_all ON public.partner_audit;
DROP POLICY IF EXISTS audit_manager_read ON public.partner_audit;
DROP POLICY IF EXISTS audit_partner_read ON public.partner_audit;
-- M21-M23 names
DROP POLICY IF EXISTS partners_select_self ON public.partners;
DROP POLICY IF EXISTS user_roles_select_self ON public.user_roles;
DROP POLICY IF EXISTS user_roles_select_manager ON public.user_roles;
DROP POLICY IF EXISTS profit_distributions_read ON public.profit_distributions;
DROP POLICY IF EXISTS profit_distributions_insert ON public.profit_distributions;
DROP POLICY IF EXISTS profit_distributions_update ON public.profit_distributions;
DROP POLICY IF EXISTS profit_distributions_delete ON public.profit_distributions;
DROP POLICY IF EXISTS profit_distribution_details_read ON public.profit_distribution_details;
DROP POLICY IF EXISTS profit_distribution_details_insert ON public.profit_distribution_details;
DROP POLICY IF EXISTS profit_distribution_details_update ON public.profit_distribution_details;
DROP POLICY IF EXISTS profit_distribution_details_delete ON public.profit_distribution_details;
DROP POLICY IF EXISTS partner_withdrawals_admin_all ON public.partner_withdrawals;
DROP POLICY IF EXISTS partner_withdrawals_self_read ON public.partner_withdrawals;
DROP POLICY IF EXISTS partner_withdrawals_self_insert ON public.partner_withdrawals;
DROP POLICY IF EXISTS partner_withdrawals_manager_read ON public.partner_withdrawals;
DROP POLICY IF EXISTS partner_withdrawals_manager_update ON public.partner_withdrawals;
DROP POLICY IF EXISTS partner_audit_admin_read ON public.partner_audit;
DROP POLICY IF EXISTS partner_audit_manager_read ON public.partner_audit;

-- ── 3. drop the functions ──────────────────────────────────────────────────────
-- M24 workflow engine
DROP FUNCTION IF EXISTS public.partner_net_profit(uuid, date, date, uuid);
DROP FUNCTION IF EXISTS public.partner_pending_withdrawal(uuid);
DROP FUNCTION IF EXISTS public.partner_summary(uuid);
DROP FUNCTION IF EXISTS public.approve_withdrawal(uuid, uuid);
DROP FUNCTION IF EXISTS public.calculate_profit_distribution(uuid, date, date, uuid);
-- M23 writers/guards
DROP FUNCTION IF EXISTS public.record_partner_audit(uuid, text, uuid, uuid, jsonb, jsonb, text, text, text);
DROP FUNCTION IF EXISTS public.guard_withdrawal_status();
DROP FUNCTION IF EXISTS public.validate_partner_withdrawal();
-- M25 RLS bridge
DROP FUNCTION IF EXISTS public.partner_in_manager_farm(uuid);

-- ── 4. drop the tables (dependents first) ─────────────────────────────────────
--   partner_withdrawals.distribution_id -> profit_distributions, and
--   profit_distribution_details.distribution_id -> profit_distributions, and
--   profit_distribution_details.partner_id / partner_withdrawals.partner_id /
--   partner_audit.partner_id -> partners, so those dependents go first.
DROP TABLE IF EXISTS public.partner_audit;
DROP TABLE IF EXISTS public.profit_distribution_details;
DROP TABLE IF EXISTS public.partner_withdrawals;
DROP TABLE IF EXISTS public.profit_distributions;
DROP TABLE IF EXISTS public.user_roles;
DROP TABLE IF EXISTS public.partners;

-- ── M1b: revenue.flock_id ─────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_validate_flock_revenue ON public.revenue;
DROP INDEX IF EXISTS public.idx_revenue_flock_direct;
DROP INDEX IF EXISTS public.idx_revenue_farm_flock;
ALTER TABLE public.revenue DROP COLUMN IF EXISTS flock_id;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $w6rbchk$
DECLARE
    v_left int;
BEGIN
    SELECT count(*) INTO v_left
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname IN ('partners','user_roles','profit_distributions',
                         'profit_distribution_details','partner_withdrawals','partner_audit');
    IF v_left <> 0 THEN
        RAISE EXCEPTION 'FAIL: % W6 table(s) survived the consolidated rollback', v_left;
    END IF;

    SELECT count(*) INTO v_left
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('partner_net_profit','partner_pending_withdrawal',
                         'partner_summary','approve_withdrawal',
                         'calculate_profit_distribution','record_partner_audit',
                         'guard_withdrawal_status','validate_partner_withdrawal',
                         'partner_in_manager_farm');
    IF v_left <> 0 THEN
        RAISE EXCEPTION 'FAIL: % W6 function(s) survived the consolidated rollback', v_left;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'revenue'
                  AND column_name = 'flock_id') THEN
        RAISE EXCEPTION 'FAIL: revenue.flock_id survived the consolidated rollback';
    END IF;

    RAISE NOTICE 'OK: W6 consolidated rollback verified - all W6 objects removed';
END;
$w6rbchk$;
