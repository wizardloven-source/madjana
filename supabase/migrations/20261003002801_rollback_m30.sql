-- ============================================================================
-- Rollback of M30 (W7.3): store + approve a profit distribution
--   20261003002801_rollback_m30.sql
-- ============================================================================
-- Removes only what M30 added. M30 changed no table, column, policy, grant or
-- row, so nothing else has to be restored: dropping the guard trigger and the
-- three functions returns the database to its exact M29v2 shape.
--
-- IDEMPOTENT. RE-RUN SAFE. NO DATA IS MODIFIED.
-- ============================================================================

BEGIN;

DROP TRIGGER IF EXISTS trg_profit_distributions_guard ON public.profit_distributions;

DROP FUNCTION IF EXISTS public.approve_profit_distribution(uuid);
DROP FUNCTION IF EXISTS public.create_profit_distribution(uuid, date, date, uuid, numeric, text, text);
DROP FUNCTION IF EXISTS public.guard_profit_distribution_status();

COMMIT;

-- ============================================================================
-- VERIFICATION
-- ============================================================================
DO $m30rbchk$
DECLARE
    v_n int;
BEGIN
    IF to_regprocedure('public.create_profit_distribution(uuid,date,date,uuid,numeric,text,text)') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: create_profit_distribution() still present after rollback';
    END IF;
    IF to_regprocedure('public.approve_profit_distribution(uuid)') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: approve_profit_distribution() still present after rollback';
    END IF;
    IF to_regprocedure('public.guard_profit_distribution_status()') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: guard_profit_distribution_status() still present after rollback';
    END IF;

    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE tgname = 'trg_profit_distributions_guard' AND NOT tgisinternal;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: guard trigger still attached after rollback';
    END IF;
END;
$m30rbchk$;
