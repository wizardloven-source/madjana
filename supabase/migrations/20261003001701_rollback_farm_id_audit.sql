-- ============================================================================
-- M18 ROLLBACK — undo farm_id_audit
--   Drop the 13 triggers, then the writer, then the ledger.
-- ============================================================================

BEGIN;

DROP TRIGGER IF EXISTS payments_farm_id_audit ON public.payments;
DROP TRIGGER IF EXISTS expenses_farm_id_audit ON public.expenses;
DROP TRIGGER IF EXISTS revenue_farm_id_audit ON public.revenue;
DROP TRIGGER IF EXISTS egg_production_farm_id_audit ON public.egg_production;
DROP TRIGGER IF EXISTS mortality_farm_id_audit ON public.mortality;
DROP TRIGGER IF EXISTS feed_consumption_farm_id_audit ON public.feed_consumption;
DROP TRIGGER IF EXISTS feed_received_farm_id_audit ON public.feed_received;
DROP TRIGGER IF EXISTS medications_farm_id_audit ON public.medications;
DROP TRIGGER IF EXISTS egg_dispatch_farm_id_audit ON public.egg_dispatch;
DROP TRIGGER IF EXISTS stock_adjustments_farm_id_audit ON public.stock_adjustments;
DROP TRIGGER IF EXISTS opening_balances_farm_id_audit ON public.opening_balances;
DROP TRIGGER IF EXISTS flock_movements_farm_id_audit ON public.flock_movements;
DROP TRIGGER IF EXISTS customers_farm_id_audit ON public.customers;

DROP FUNCTION IF EXISTS public.trg_farm_id_audit();

DROP TABLE IF EXISTS public.farm_id_audit;

COMMIT;

DO $m18rb$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_proc WHERE proname='trg_farm_id_audit';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: trg_farm_id_audit survived rollback';
    END IF;
    SELECT count(*) INTO v_n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relname='farm_id_audit';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: farm_id_audit survived rollback';
    END IF;
    RAISE NOTICE 'OK: M18 rollback verified - farm_id_audit removed';
END;
$m18rb$;