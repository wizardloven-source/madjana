-- ============================================================
-- W8 rollback: ربط إنتاج/تخريج البيض بمخزون صحون الكرتون
-- ============================================================
-- يعكس 20261003002900_inventory_trays_tracking.sql
-- ملاحظة: build_test_db.py يتخطى أي ملف يحوي "rollback" فلا يُطبّق تلقائيًا.
-- ============================================================

BEGIN;

-- (f) إسقاط الـ triggers
DROP TRIGGER IF EXISTS trg_trays_on_production ON public.egg_production;
DROP TRIGGER IF EXISTS trg_trays_on_dispatch ON public.egg_dispatch;
DROP TRIGGER IF EXISTS trg_trays_on_carton_purchase ON public.expenses;

DROP FUNCTION IF EXISTS public.trays_on_production();
DROP FUNCTION IF EXISTS public.trays_on_dispatch();
DROP FUNCTION IF EXISTS public.trays_on_carton_purchase();
DROP FUNCTION IF EXISTS public.apply_inventory_system_delta(uuid, text, text, numeric, text, uuid, timestamptz);
DROP FUNCTION IF EXISTS public.ensure_inventory_system_item(uuid, text, text, numeric);

-- (d) استرجاع الدالتين الأصليتين
CREATE OR REPLACE FUNCTION public.protect_inventory_quantity()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.quantity IS DISTINCT FROM OLD.quantity THEN
        RAISE EXCEPTION 'لا يمكن تعديل الرصيد مباشرة. استخدم معاملات المخزون';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.prevent_negative_inventory_quantity()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.quantity < 0 THEN
    RAISE EXCEPTION 'Inventory quantity cannot be negative. Attempted: %', NEW.quantity;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- (d3) استرجاع populate_sync_changes الأصلي (init.sql)
CREATE OR REPLACE FUNCTION public.populate_sync_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id uuid;
    v_farm_id uuid;
    v_op      text;
    v_payload jsonb;
BEGIN
    IF current_setting('app.skip_sync_trigger', true) = 'on' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    v_user_id := auth.uid();
    IF v_user_id IS NULL OR v_user_id::text = '00000000-0000-0000-0000-000000000000' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    v_farm_id := COALESCE(NEW.farm_id, OLD.farm_id);
    IF v_farm_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    IF TG_OP = 'INSERT' THEN v_op := 'INSERT';
    ELSIF TG_OP = 'UPDATE' THEN v_op := 'UPDATE';
    ELSE v_op := 'DELETE';
    END IF;

    IF TG_OP = 'DELETE' THEN
        v_payload := to_jsonb(OLD);
    ELSE
        v_payload := to_jsonb(NEW);
    END IF;
    v_payload := v_payload - 'sync_status' - 'deleted_at';

    INSERT INTO sync_changes (table_name, record_id, operation, farm_id, user_id, payload)
    VALUES (TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), v_op, v_farm_id, v_user_id, v_payload);

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- (c) استرجاع قيد quantity >= 0
ALTER TABLE public.inventory_items
    DROP CONSTRAINT IF EXISTS inventory_items_quantity_check;
ALTER TABLE public.inventory_items
    ADD CONSTRAINT inventory_items_quantity_check CHECK (quantity >= 0);

-- (g) إسقاط سياسة قراءة العامل
DROP POLICY IF EXISTS inventory_items_worker_select ON public.inventory_items;

-- (h) استرجاع sync_can_read/write إلى النسخة الرسمية الحالية
--     (20260926000100_sync_publish_revenue_and_occ.sql) دون inventory_items للعامل
CREATE OR REPLACE FUNCTION public.sync_can_write(p_role text, p_table text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT
        CASE p_role
            WHEN 'worker' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications', 'revenue',
                'dispatch_requests'
            )
            WHEN 'manager' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications',
                'customers', 'flocks', 'expenses', 'payments',
                'inventory_items', 'inventory_transactions',
                'opening_balances', 'revenue', 'stock_adjustments',
                'dispatch_requests'
            )
            WHEN 'system_admin' THEN p_table NOT IN ('users', 'farms')
            ELSE false
        END;
$$;

CREATE OR REPLACE FUNCTION public.sync_can_read(p_role text, p_table text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT
        CASE p_role
            WHEN 'worker' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications', 'revenue',
                'dispatch_requests'
            )
            WHEN 'manager' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications',
                'customers', 'flocks', 'expenses', 'payments',
                'inventory_items', 'inventory_transactions',
                'opening_balances', 'revenue', 'stock_adjustments',
                'dispatch_requests'
            )
            WHEN 'system_admin' THEN p_table NOT IN ('users', 'farms')
            ELSE false
        END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_can_write(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_can_write(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.sync_can_read(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_can_read(text, text) TO service_role;

-- (e) حذف عنصري النظام
DELETE FROM public.inventory_items WHERE system_key IN ('trays_empty', 'trays_filled');

-- (b) إسقاط system_key
DROP INDEX IF EXISTS public.ux_inventory_items_farm_system_key;
ALTER TABLE public.inventory_items DROP COLUMN IF EXISTS system_key;

-- (a) إسقاط trays_per_bundle
ALTER TABLE public.farms DROP COLUMN IF EXISTS trays_per_bundle;

COMMIT;
