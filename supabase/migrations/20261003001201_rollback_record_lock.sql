-- ============================================================================
-- M13 ROLLBACK — undo record_lock
--   Drop the guard triggers, the trigger function, and the two tables.
--   Order matters: record_unlock_requests FK -> record_lock, so it drops first.
--   Idempotent: every DROP is guarded, re-running after a migration from a
--   different branch is a no-op.
-- ============================================================================

BEGIN;

DROP TRIGGER IF EXISTS payments_lock_guard ON public.payments;
DROP TRIGGER IF EXISTS expenses_lock_guard ON public.expenses;
DROP TRIGGER IF EXISTS revenue_lock_guard ON public.revenue;
DROP TRIGGER IF EXISTS egg_production_lock_guard ON public.egg_production;
DROP TRIGGER IF EXISTS mortality_lock_guard ON public.mortality;
DROP TRIGGER IF EXISTS feed_consumption_lock_guard ON public.feed_consumption;

DROP FUNCTION IF EXISTS public.assert_record_not_locked();

DROP TABLE IF EXISTS public.record_unlock_requests;
DROP TABLE IF EXISTS public.record_lock;

COMMIT;

DO $m13rb$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname='assert_record_not_locked';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: assert_record_not_locked survived rollback';
    END IF;
    SELECT count(*) INTO v_n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relname IN ('record_lock','record_unlock_requests');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: record_lock tables survived rollback';
    END IF;
    RAISE NOTICE 'OK: M13 rollback verified - record_lock removed';
END;
$m13rb$;