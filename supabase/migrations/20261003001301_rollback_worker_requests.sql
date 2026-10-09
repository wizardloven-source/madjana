-- ============================================================================
-- M14 ROLLBACK — undo change_requests (sync table)
--   Drop the four sync triggers, then the registry row, then the table.
--   Idempotent: every DROP guarded.
-- ============================================================================

BEGIN;

DROP TRIGGER IF EXISTS change_requests_sync_insert ON public.change_requests;
DROP TRIGGER IF EXISTS change_requests_sync_update ON public.change_requests;
DROP TRIGGER IF EXISTS change_requests_tombstone ON public.change_requests;
DROP TRIGGER IF EXISTS change_requests_updated_at ON public.change_requests;

DELETE FROM public.sync_table_registry WHERE table_name = 'change_requests';

DROP TABLE IF EXISTS public.change_requests;

COMMIT;

DO $m14rb$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM public.sync_table_registry
     WHERE table_name='change_requests';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: change_requests registry row survived rollback';
    END IF;
    SELECT count(*) INTO v_n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relname='change_requests';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: change_requests table survived rollback';
    END IF;
    RAISE NOTICE 'OK: M14 rollback verified - change_requests removed';
END;
$m14rb$;