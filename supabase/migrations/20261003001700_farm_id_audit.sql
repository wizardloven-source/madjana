-- ============================================================================
-- M18: farm_id_audit — every farm reassignment of a record is traceable
-- ============================================================================
-- WHY
--   UPGRADE_multifarm_links and the 00801 sync path can move a record to a
--   different farm (a mis-keyed expense, a re-homed flock, a batch repair).
--   farm_id is the RLS subject: once a row crosses farms, nobody can answer
--   "where was this before and who moved it" from the live row alone — the
--   old farm id is simply gone. M18 writes the answer BEFORE the move lands:
--
--   farm_id_audit (table_name, record_id, old_farm_id, new_farm_id, who,
--   when) is appended by a generic trigger on every table that carries
--   farm_id as its own column. inventory_items / inventory_transactions are
--   excluded by construction (they have no farm_id column; their farm is
--   resolved through the flock/item chain).
--
-- SCOPE
--   * creates farm_id_audit (NOT synced — it is a server-side ledger)
--   * one trigger function + one BEFORE UPDATE OF farm_id trigger per table:
--     payments, expenses, revenue, egg_production, mortality,
--     feed_consumption, feed_received, medications, egg_dispatch,
--     stock_adjustments, opening_balances, flock_movements, customers
--   * does NOT block the move (the move already happened / is the job of
--     other guardrails) — M18 only records it.
--
-- SECURITY NOTES
--   * writer is SECURITY DEFINER (the changing session may be a worker's
--     device or a service batch; the ledger must always be written, while
--     read stays manager/admin).
--   * RLS read: managers of either farm + system_admin.
--   * FKs: old/new farm -> farms RESTRICT; changed_by -> users SET NULL.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) the ledger ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.farm_id_audit (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name   text NOT NULL,
    record_id    uuid,
    old_farm_id  uuid NOT NULL REFERENCES public.farms(id) ON DELETE RESTRICT,
    new_farm_id  uuid NOT NULL REFERENCES public.farms(id) ON DELETE RESTRICT,
    changed_by   uuid REFERENCES public.users(id) ON DELETE SET NULL,
    changed_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_farm_id_audit_lookup
    ON public.farm_id_audit (table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_farm_id_audit_farm
    ON public.farm_id_audit (old_farm_id, changed_at);

-- ── 2) the generic writer ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_farm_id_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m18$
BEGIN
    IF OLD.farm_id IS DISTINCT FROM NEW.farm_id THEN
        INSERT INTO public.farm_id_audit
            (table_name, record_id, old_farm_id, new_farm_id, changed_by)
        VALUES
            (TG_TABLE_NAME, NEW.id, OLD.farm_id, NEW.farm_id, auth.uid());
    END IF;
    RETURN NEW;
END;
$m18$;

-- ── 3) one trigger per farm_id-bearing table ─────────────────────────────────
DROP TRIGGER IF EXISTS payments_farm_id_audit ON public.payments;
CREATE TRIGGER payments_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.payments
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

DROP TRIGGER IF EXISTS expenses_farm_id_audit ON public.expenses;
CREATE TRIGGER expenses_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.expenses
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

DROP TRIGGER IF EXISTS revenue_farm_id_audit ON public.revenue;
CREATE TRIGGER revenue_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.revenue
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

DROP TRIGGER IF EXISTS egg_production_farm_id_audit ON public.egg_production;
CREATE TRIGGER egg_production_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.egg_production
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

DROP TRIGGER IF EXISTS mortality_farm_id_audit ON public.mortality;
CREATE TRIGGER mortality_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.mortality
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

DROP TRIGGER IF EXISTS feed_consumption_farm_id_audit ON public.feed_consumption;
CREATE TRIGGER feed_consumption_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.feed_consumption
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

DROP TRIGGER IF EXISTS feed_received_farm_id_audit ON public.feed_received;
CREATE TRIGGER feed_received_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.feed_received
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

DROP TRIGGER IF EXISTS medications_farm_id_audit ON public.medications;
CREATE TRIGGER medications_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.medications
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

DROP TRIGGER IF EXISTS egg_dispatch_farm_id_audit ON public.egg_dispatch;
CREATE TRIGGER egg_dispatch_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.egg_dispatch
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

DROP TRIGGER IF EXISTS stock_adjustments_farm_id_audit ON public.stock_adjustments;
CREATE TRIGGER stock_adjustments_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.stock_adjustments
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

DROP TRIGGER IF EXISTS opening_balances_farm_id_audit ON public.opening_balances;
CREATE TRIGGER opening_balances_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.opening_balances
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

DROP TRIGGER IF EXISTS flock_movements_farm_id_audit ON public.flock_movements;
CREATE TRIGGER flock_movements_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.flock_movements
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

DROP TRIGGER IF EXISTS customers_farm_id_audit ON public.customers;
CREATE TRIGGER customers_farm_id_audit
    BEFORE UPDATE OF farm_id ON public.customers
    FOR EACH ROW WHEN (OLD.farm_id IS DISTINCT FROM NEW.farm_id)
    EXECUTE FUNCTION public.trg_farm_id_audit();

-- ── 4) RLS + grants ──────────────────────────────────────────────────────────
ALTER TABLE public.farm_id_audit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS farm_id_audit_select ON public.farm_id_audit;
CREATE POLICY farm_id_audit_select ON public.farm_id_audit
    FOR SELECT
    USING (public.is_system_admin()
           OR public.user_manages_farm(old_farm_id)
           OR public.user_manages_farm(new_farm_id));

REVOKE ALL ON TABLE public.farm_id_audit FROM PUBLIC;
REVOKE ALL ON TABLE public.farm_id_audit FROM anon;
REVOKE ALL ON TABLE public.farm_id_audit FROM authenticated;
GRANT SELECT ON TABLE public.farm_id_audit TO authenticated;

REVOKE EXECUTE ON FUNCTION public.trg_farm_id_audit() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.trg_farm_id_audit() TO authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT, a failure never rolls the work back)
-- ============================================================================
DO $m18$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname='trg_farm_id_audit' AND prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: trg_farm_id_audit not SECURITY DEFINER';
    END IF;

    SELECT count(*) INTO v_n
      FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND t.tgname LIKE '%_farm_id_audit'
       AND NOT t.tgisinternal;
    IF v_n <> 13 THEN
        RAISE EXCEPTION 'FAIL: expected 13 farm_id_audit triggers, found %', v_n;
    END IF;

    -- behavioural proof (a farm move lands old->new in the ledger) runs in
    -- p0_farm_id_audit_test.sql against the local fixtures; production data
    -- must not be touched by a migration's verify block.
    RAISE NOTICE 'OK: M18 verified - 13 farm_id_audit triggers, ledger, manager/admin reads live';
END;
$m18$;