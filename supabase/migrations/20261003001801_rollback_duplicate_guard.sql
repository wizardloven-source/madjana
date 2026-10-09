-- ============================================================================
-- M19 ROLLBACK — undo duplicate_guard
--   Drop six gates, both functions, then the marker table.
-- ============================================================================

BEGIN;

DROP TRIGGER IF EXISTS expenses_duplicate_guard ON public.expenses;
DROP TRIGGER IF EXISTS egg_production_duplicate_guard ON public.egg_production;
DROP TRIGGER IF EXISTS mortality_duplicate_guard ON public.mortality;
DROP TRIGGER IF EXISTS feed_consumption_duplicate_guard ON public.feed_consumption;
DROP TRIGGER IF EXISTS feed_received_duplicate_guard ON public.feed_received;
DROP TRIGGER IF EXISTS payments_duplicate_guard ON public.payments;

DROP FUNCTION IF EXISTS public.trg_duplicate_guard();
DROP FUNCTION IF EXISTS public.dup_fingerprint(text, jsonb);

DROP TABLE IF EXISTS public.duplicate_guard;

COMMIT;

DO $m19rb$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname IN ('trg_duplicate_guard','dup_fingerprint');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: duplicate-guard functions survived rollback';
    END IF;
    SELECT count(*) INTO v_n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relname='duplicate_guard';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: duplicate_guard survived rollback';
    END IF;
    RAISE NOTICE 'OK: M19 rollback verified - duplicate_guard removed';
END;
$m19rb$;