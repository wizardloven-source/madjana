-- ============================================================================
-- M15: invoice_audit — wire the dispatched-egg invoice changes into audit_log
-- ============================================================================
-- WHY
--   egg_dispatch is the invoice record: cartons/trays/total_eggs/customer/
--   tray_weight/payment_status are the numbers a farm disputes or needs to
--   re-trace weeks later ("who changed this dispatch, and from what to
--   what?"). audit_log ALREADY exists in production (id, farm_id, user_id,
--   action, table_name, record_id, old_values, new_values, device_id,
--   ip_address, correlation_id, created_at) but no trigger populates it for
--   the invoice table — the audit trail is empty exactly where it matters.
--
--   M15 attaches BEFORE triggers to egg_dispatch (update of the invoice
--   columns, or delete) that write old/new snapshots to audit_log and stamp
--   the acting user. Nothing else changes.
--
-- SCOPE
--   * adds NO columns (audit_log already has table_name/action since the
--     base snapshot), NO new tables, NO data changes.
--   * two triggers + one trigger function, on egg_dispatch only.
--
-- SECURITY NOTES
--   * the trigger function is SECURITY DEFINER ON PURPOSE: workers may update
--     their own dispatches, but audit_log grants SELECT only (audit_select_
--     manager) — an invoker-context insert would be refused by RLS and fail
--     the worker's own UPDATE. The definer writes the audit row; the read
--     policy stays manager-only.
--   * user_id = auth.uid() at write time (null for pure service batches).
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) the audit writer ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_audit_invoice()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m15$
DECLARE
    v_user uuid;
BEGIN
    v_user := auth.uid();

    IF TG_OP = 'UPDATE' THEN
        INSERT INTO public.audit_log
            (farm_id, user_id, action, table_name, record_id,
             old_values, new_values)
        VALUES
            (NEW.farm_id, v_user, 'UPDATE', 'egg_dispatch', NEW.id,
             to_jsonb(OLD), to_jsonb(NEW));
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO public.audit_log
            (farm_id, user_id, action, table_name, record_id,
             old_values, new_values)
        VALUES
            (OLD.farm_id, v_user, 'DELETE', 'egg_dispatch', OLD.id,
             to_jsonb(OLD), NULL);
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$m15$;

-- ── 2) invoice-column updates ────────────────────────────────────────────────
DROP TRIGGER IF EXISTS egg_dispatch_invoice_audit_update ON public.egg_dispatch;
CREATE TRIGGER egg_dispatch_invoice_audit_update
    BEFORE UPDATE OF cartons, trays, total_eggs, customer_id,
                      tray_weight_kg, payment_status, notes
    ON public.egg_dispatch
    FOR EACH ROW
    WHEN (OLD.* IS DISTINCT FROM NEW.*)
    EXECUTE FUNCTION public.trg_audit_invoice();

-- ── 3) deletes ───────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS egg_dispatch_invoice_audit_delete ON public.egg_dispatch;
CREATE TRIGGER egg_dispatch_invoice_audit_delete
    BEFORE DELETE
    ON public.egg_dispatch
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_audit_invoice();

-- ── 4) grants ────────────────────────────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.trg_audit_invoice() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.trg_audit_invoice() TO authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m15$
DECLARE
    v_n int;
BEGIN
    -- the writer is live and SECURITY DEFINER
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname='trg_audit_invoice' AND prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: trg_audit_invoice not SECURITY DEFINER';
    END IF;

    SELECT count(*) INTO v_n
      FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relname='egg_dispatch'
       AND t.tgname IN ('egg_dispatch_invoice_audit_update',
                        'egg_dispatch_invoice_audit_delete')
       AND NOT t.tgisinternal;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FAIL: expected 2 egg_dispatch audit triggers, found %', v_n;
    END IF;

    -- behavioural proof (an edit and a delete both land in audit_log) runs in
    -- p0_invoice_audit_test.sql against the local fixture users; production
    -- data must not be touched by a migration's verify block.
    RAISE NOTICE 'OK: M15 verified - egg_dispatch audit triggers + writer live';
END;
$m15$;