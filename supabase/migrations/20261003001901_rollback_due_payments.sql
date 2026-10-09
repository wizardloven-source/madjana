-- ============================================================================
-- M20 ROLLBACK — undo due_payments notifier
--   Drop the optional cron job (only if the extension still exists), then the
--   function. Notification rows already created stay; they are normal data.
-- ============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.check_due_payments();

COMMIT;

DO $m20rb$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        DELETE FROM cron.job WHERE jobname = 'madjana_due_payments';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname='check_due_payments') THEN
        RAISE EXCEPTION 'FAIL: check_due_payments survived rollback';
    END IF;
    RAISE NOTICE 'OK: M20 rollback verified - due-payments notifier removed';
END;
$m20rb$;