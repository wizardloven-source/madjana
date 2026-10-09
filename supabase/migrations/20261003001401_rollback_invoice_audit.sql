-- ============================================================================
-- M15 ROLLBACK — undo invoice_audit wiring
--   Drop the egg_dispatch triggers and the audit writer. audit_log itself
--   stays (it existed before M15 and is shared state).
-- ============================================================================

BEGIN;

DROP TRIGGER IF EXISTS egg_dispatch_invoice_audit_update ON public.egg_dispatch;
DROP TRIGGER IF EXISTS egg_dispatch_invoice_audit_delete ON public.egg_dispatch;

DROP FUNCTION IF EXISTS public.trg_audit_invoice();

COMMIT;

DO $m15rb$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_proc WHERE proname='trg_audit_invoice';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: trg_audit_invoice survived rollback';
    END IF;
    SELECT count(*) INTO v_n
      FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relname='egg_dispatch'
       AND t.tgname LIKE 'egg_dispatch_invoice_audit_%' AND NOT t.tgisinternal;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: egg_dispatch audit triggers survived rollback';
    END IF;
    RAISE NOTICE 'OK: M15 rollback verified - egg_dispatch audit wiring removed';
END;
$m15rb$;