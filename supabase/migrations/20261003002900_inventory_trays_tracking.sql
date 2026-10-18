-- ============================================================
-- W8: ربط إنتاج/تخريج البيض بمخزون صحون الكرتون
-- ============================================================
-- المشكلة:
--   مخزون صحون الكرتون كان مُشتقًّا في واجهة الديسكتوب فقط (شراء − تخريج)
--   وغير محفوظ ولا يُزامَن. ولا يوجد أي رابط فعلي بين الإنتاج/التخريج
--   وجدول inventory_items.
--
-- النموذج المعتمد (مخزونان + triggers):
--   trays_empty  «صحون فارغة»  (piece): + عند الشراء، − عند الإنتاج
--   trays_filled «صحون معبئة»  (piece): + عند الإنتاج،  − عند التخريج
--   كراتين البيض تُشتق من الصحون (trays_per_carton)، لا عدّاد منفصل.
--   السجل محفوظ في inventory_transactions (لا stock_adjustments).
--
-- البنود:
--   a) farms.trays_per_bundle
--   b) inventory_items.system_key + unique (farm_id, system_key)
--   c) إسقاط CHECK (quantity >= 0) — السجل هو مصدر الحقيقة (قد يصبح سالبًا مؤقتًا)
--   d) الدالتان protect_inventory_quantity / prevent_negative_inventory_quantity
--   e) backfill_inventory_trays: رصيد افتتاحي محسوب من التاريخ لكل مزرعة
--   f) 3 triggers AFTER INSERT OR UPDATE OR DELETE (production/dispatch/purchase)
--   g) RLS: قراءة العامل لـ inventory_items
--   h) إعادة إرسال sync_can_read (إضافة inventory_items لقراءة العامل)
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- (a) farms.trays_per_bundle — عدد الصحون في الربطة (افتراضي 100)
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.farms
    ADD COLUMN IF NOT EXISTS trays_per_bundle INTEGER NOT NULL DEFAULT 100
        CHECK (trays_per_bundle > 0);

-- ────────────────────────────────────────────────────────────
-- (b) inventory_items.system_key — مفتاح ثابت لا يتأثر بإعادة التسمية
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.inventory_items
    ADD COLUMN IF NOT EXISTS system_key TEXT;

-- UNIQUE (farm_id, system_key): القيم NULL متعددة مسموحة (عناصر المستخدم العادية)
CREATE UNIQUE INDEX IF NOT EXISTS ux_inventory_items_farm_system_key
    ON public.inventory_items (farm_id, system_key);

-- ────────────────────────────────────────────────────────────
-- (c) إسقاط قيد quantity >= 0
--     السبب: صحون النظام تُخصم عبر trigger؛ لو نقص الرصيد نريد تسجيلًا
--     وتحذيرًا (WARNING) لا فشلًا يعطّل تسجيل الإنتاج. السجل (ledger) هو
--     مصدر الحقيقة، والتحذير يُظهر أي خلل.
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.inventory_items
    DROP CONSTRAINT IF EXISTS inventory_items_quantity_check;

-- ────────────────────────────────────────────────────────────
-- (d1) protect_inventory_quantity — يسمح بالتعديل عندما يضبط trigger
--      النظام مفتاح app.allow_inventory_update (transaction-local).
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.protect_inventory_quantity()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.quantity IS DISTINCT FROM OLD.quantity
       AND COALESCE(current_setting('app.allow_inventory_update', true), 'off') <> 'on'
    THEN
        RAISE EXCEPTION 'لا يمكن تعديل الرصيد مباشرة. استخدم معاملات المخزون';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- (d2) prevent_negative_inventory_quantity — عناصر النظام: تحذير لا استثناء
CREATE OR REPLACE FUNCTION public.prevent_negative_inventory_quantity()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.quantity < 0 THEN
        IF NEW.system_key IS NOT NULL THEN
            RAISE WARNING 'مخزون النظام % (مزرعة %) أصبح سالبًا: %',
                NEW.system_key, NEW.farm_id, NEW.quantity;
        ELSE
            RAISE EXCEPTION 'Inventory quantity cannot be negative. Attempted: %', NEW.quantity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- (d3) populate_sync_changes — عيب كامن: كان يقرأ NEW.farm_id دائمًا،
--      لكن inventory_transactions لا يملك farm_id (يستمدّه من العنصر).
--      أي إدراج خادمي في السجل كان يفشل بـ «record new has no field farm_id».
--      الإصلاح: استخراج آمن عبر to_jsonb، واستمداد مزرعة السجل عبر العنصر.
--      (كانت كتابة السجل عبر sync_records_batch تعمل لأنها تتخطّى هذا الـtrigger.)
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

    IF TG_TABLE_NAME = 'inventory_transactions' THEN
        SELECT i.farm_id INTO v_farm_id
          FROM public.inventory_items i
         WHERE i.id = COALESCE(NEW.item_id, OLD.item_id);
    ELSE
        -- to_jsonb لا يرمي عند غياب الحقل، بعكس NEW.farm_id المباشر
        v_farm_id := COALESCE(
            (to_jsonb(NEW) ->> 'farm_id')::uuid,
            (to_jsonb(OLD) ->> 'farm_id')::uuid
        );
    END IF;

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

-- ────────────────────────────────────────────────────────────
-- المساعدات: إنشاء عنصر نظام عند الحاجة + تطبيق فرق + كتابة السجل
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ensure_inventory_system_item(
    p_farm_id uuid,
    p_system_key text,
    p_name text,
    p_low numeric DEFAULT 0
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id uuid;
BEGIN
    SELECT id INTO v_id
      FROM inventory_items
     WHERE farm_id = p_farm_id AND system_key = p_system_key;

    IF v_id IS NULL THEN
        INSERT INTO inventory_items
            (farm_id, name, unit, quantity, low_stock_threshold, system_key)
        VALUES
            (p_farm_id, p_name, 'piece', 0, p_low, p_system_key)
        ON CONFLICT DO NOTHING;

        SELECT id INTO v_id
          FROM inventory_items
         WHERE farm_id = p_farm_id AND system_key = p_system_key;

        -- تبنّي عنصر موجود بنفس الاسم ولكن بلا system_key
        IF v_id IS NULL THEN
            SELECT id INTO v_id
              FROM inventory_items
             WHERE farm_id = p_farm_id AND name = p_name;
            IF v_id IS NOT NULL THEN
                UPDATE inventory_items SET system_key = p_system_key WHERE id = v_id;
            END IF;
        END IF;
    END IF;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_inventory_system_delta(
    p_farm_id uuid,
    p_system_key text,
    p_name text,
    p_delta numeric,
    p_note text,
    p_user_id uuid,
    p_date timestamptz DEFAULT now()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id uuid;
    v_new numeric;
BEGIN
    IF p_delta IS NULL OR p_delta = 0 THEN
        RETURN;
    END IF;

    v_id := public.ensure_inventory_system_item(p_farm_id, p_system_key, p_name);
    IF v_id IS NULL THEN
        RAISE WARNING 'تعذّر إنشاء عنصر النظام % للمزرعة %', p_system_key, p_farm_id;
        RETURN;
    END IF;

    -- السماح بتجاوز حارس protect_inventory_quantity داخل هذا الترانزاكشن فقط
    PERFORM set_config('app.allow_inventory_update', 'on', true);

    UPDATE inventory_items
       SET quantity   = quantity + p_delta,
           version    = version + 1,
           updated_at = now()
     WHERE id = v_id
    RETURNING quantity INTO v_new;

    PERFORM set_config('app.allow_inventory_update', 'off', true);

    INSERT INTO inventory_transactions (item_id, date, type, quantity, note, user_id)
    VALUES (
        v_id,
        COALESCE(p_date, now()),
        CASE WHEN p_delta > 0 THEN 'in' ELSE 'out' END,
        abs(p_delta),
        p_note,
        p_user_id
    );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- (f1) trigger الإنتاج: صحون معبئة (+) / صحون فارغة (−)
--      delta = CEIL(new_eggs / eggs_per_tray) − CEIL(old_eggs / eggs_per_tray)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trays_on_production()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tray_size int;
    v_old int;
    v_new int;
    v_farm uuid;
    v_worker uuid;
    v_date date;
    v_delta int;
BEGIN
    v_farm := COALESCE(NEW.farm_id, OLD.farm_id);
    v_date := COALESCE(NEW.date, OLD.date);
    v_worker := COALESCE(NEW.worker_id, OLD.worker_id);

    SELECT COALESCE(eggs_per_tray, 30) INTO v_tray_size
      FROM farms WHERE id = v_farm;
    v_tray_size := COALESCE(v_tray_size, 30);

    IF TG_OP = 'INSERT' THEN
        v_old := 0;
        v_new := COALESCE(NEW.total_eggs, 0);
    ELSIF TG_OP = 'UPDATE' THEN
        v_old := COALESCE(OLD.total_eggs, 0);
        v_new := COALESCE(NEW.total_eggs, 0);
    ELSE
        v_old := COALESCE(OLD.total_eggs, 0);
        v_new := 0;
    END IF;

    v_delta := CEIL(v_new::numeric / v_tray_size) - CEIL(v_old::numeric / v_tray_size);
    IF v_delta = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    -- صحون معبئة: تزيد بالإنتاج
    PERFORM public.apply_inventory_system_delta(
        v_farm, 'trays_filled', 'صحون معبئة', v_delta,
        'إنتاج بيض', v_worker, v_date::timestamptz);

    -- صحون فارغة: تُستهلك بالإنتاج (عكس الإشارة)
    PERFORM public.apply_inventory_system_delta(
        v_farm, 'trays_empty', 'صحون فارغة', -v_delta,
        'استهلاك صحون فارغة في الإنتاج', v_worker, v_date::timestamptz);

    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_trays_on_production ON public.egg_production;
CREATE TRIGGER trg_trays_on_production
    AFTER INSERT OR UPDATE OR DELETE ON public.egg_production
    FOR EACH ROW EXECUTE FUNCTION public.trays_on_production();

-- ────────────────────────────────────────────────────────────
-- (f2) trigger التخريج: صحون معبئة (−)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trays_on_dispatch()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tray_size int;
    v_old int;
    v_new int;
    v_farm uuid;
    v_worker uuid;
    v_date date;
    v_delta int;
BEGIN
    v_farm := COALESCE(NEW.farm_id, OLD.farm_id);
    v_date := COALESCE(NEW.date, OLD.date);
    v_worker := COALESCE(NEW.worker_id, OLD.worker_id);

    SELECT COALESCE(eggs_per_tray, 30) INTO v_tray_size
      FROM farms WHERE id = v_farm;
    v_tray_size := COALESCE(v_tray_size, 30);

    IF TG_OP = 'INSERT' THEN
        v_old := 0;
        v_new := COALESCE(NEW.total_eggs, 0);
    ELSIF TG_OP = 'UPDATE' THEN
        v_old := COALESCE(OLD.total_eggs, 0);
        v_new := COALESCE(NEW.total_eggs, 0);
    ELSE
        v_old := COALESCE(OLD.total_eggs, 0);
        v_new := 0;
    END IF;

    v_delta := CEIL(v_old::numeric / v_tray_size) - CEIL(v_new::numeric / v_tray_size);
    IF v_delta = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    -- صحون معبئة: تنقص بالتخريج
    PERFORM public.apply_inventory_system_delta(
        v_farm, 'trays_filled', 'صحون معبئة', v_delta,
        'تخريج بيض', v_worker, v_date::timestamptz);

    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_trays_on_dispatch ON public.egg_dispatch;
CREATE TRIGGER trg_trays_on_dispatch
    AFTER INSERT OR UPDATE OR DELETE ON public.egg_dispatch
    FOR EACH ROW EXECUTE FUNCTION public.trays_on_dispatch();

-- ────────────────────────────────────────────────────────────
-- (f3) trigger شراء الكرتون (expenses.category='carton'): صحون فارغة (+)
--      delta = (new_bundles − old_bundles) × trays_per_bundle
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trays_on_carton_purchase()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_farm uuid;
    v_bundle int;
    v_old int;
    v_new int;
    v_date date;
    v_delta int;
BEGIN
    -- نتجاهل أي تصنيف غير carton
    IF TG_OP = 'DELETE' THEN
        IF COALESCE(OLD.category, '') <> 'carton' THEN
            RETURN OLD;
        END IF;
    ELSE
        IF COALESCE(NEW.category, '') <> 'carton' THEN
            RETURN NEW;
        END IF;
    END IF;

    v_farm := COALESCE(NEW.farm_id, OLD.farm_id);
    v_date := COALESCE(NEW.date, OLD.date);

    SELECT COALESCE(trays_per_bundle, 100) INTO v_bundle
      FROM farms WHERE id = v_farm;
    v_bundle := COALESCE(v_bundle, 100);

    IF TG_OP = 'INSERT' THEN
        v_old := 0;
        v_new := COALESCE(NEW.carton_bundles, 0);
    ELSIF TG_OP = 'UPDATE' THEN
        v_old := COALESCE(OLD.carton_bundles, 0);
        v_new := COALESCE(NEW.carton_bundles, 0);
    ELSE
        v_old := COALESCE(OLD.carton_bundles, 0);
        v_new := 0;
    END IF;

    v_delta := (v_new - v_old) * v_bundle;
    IF v_delta = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    PERFORM public.apply_inventory_system_delta(
        v_farm, 'trays_empty', 'صحون فارغة', v_delta,
        'شراء صحون كرتون', auth.uid(), v_date::timestamptz);

    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_trays_on_carton_purchase ON public.expenses;
CREATE TRIGGER trg_trays_on_carton_purchase
    AFTER INSERT OR UPDATE OR DELETE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.trays_on_carton_purchase();

-- ────────────────────────────────────────────────────────────
-- (e) backfill_inventory_trays — الرصيد الافتتاحي التاريخي لمزرعة
--     الـtriggers تُحدّث الصحون عند الحركات الجديدة فقط؛ لتفادي تناقض
--     «رصيد بيض ≠ صحون معبئة» نحسب رصيدًا افتتاحيًا من التاريخ:
--
--       صافي البيض (الصالح) = Σ(total_eggs − broken − dirty)        [إنتاج]
--                            − Σ(total_eggs)                        [تخريج]
--                            + Σ(eggs_produced − eggs_dispatched)   [أرصدة افتتاحية]
--                            + Σ(delta_qty) WHERE stock_type='eggs'  [تسويات]
--
--       filled = CEIL( GREATEST(صافي البيض, 0) / eggs_per_tray )
--       empty  = GREATEST( Σ(carton_bundles) × trays_per_bundle − filled, 0 )
--
--     ملاحظة: التخريج لا يعيد الصحون الفارغة (الزبون يحتفظ بها)، لذا
--     «فارغة» تُشتق من الشراء والإنتاج فقط، لا من التخريج.
--     المعادلة تطابق تعريف «رصيد البيض» في واجهة الديسكتوب.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.backfill_inventory_trays(p_farm_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tray   int;
    v_bundle int;
    v_net    numeric;
    v_filled numeric;
    v_empty  numeric;
    v_fid    uuid;
    v_eid    uuid;
BEGIN
    SELECT GREATEST(COALESCE(eggs_per_tray, 30), 1),
           GREATEST(COALESCE(trays_per_bundle, 100), 1)
      INTO v_tray, v_bundle
      FROM public.farms WHERE id = p_farm_id;
    v_tray := COALESCE(v_tray, 30);
    v_bundle := COALESCE(v_bundle, 100);

    SELECT
          COALESCE((SELECT SUM(total_eggs - COALESCE(broken_eggs, 0)
                                         - COALESCE(dirty_eggs, 0))
                      FROM public.egg_production
                     WHERE farm_id = p_farm_id AND deleted_at IS NULL), 0)
        - COALESCE((SELECT SUM(total_eggs)
                      FROM public.egg_dispatch
                     WHERE farm_id = p_farm_id AND deleted_at IS NULL), 0)
        + COALESCE((SELECT SUM(eggs_produced) - SUM(eggs_dispatched)
                      FROM public.opening_balances
                     WHERE farm_id = p_farm_id), 0)
        + COALESCE((SELECT SUM(delta_qty)
                      FROM public.stock_adjustments
                     WHERE farm_id = p_farm_id AND stock_type = 'eggs'
                       AND deleted_at IS NULL), 0)
      INTO v_net;

    v_filled := GREATEST(CEIL(GREATEST(v_net, 0) / v_tray), 0);
    v_empty  := GREATEST(
        COALESCE((SELECT SUM(carton_bundles)
                    FROM public.expenses
                   WHERE farm_id = p_farm_id AND category = 'carton'
                     AND deleted_at IS NULL), 0) * v_bundle - v_filled,
        0);

    v_eid := public.ensure_inventory_system_item(
        p_farm_id, 'trays_empty', 'صحون فارغة');
    v_fid := public.ensure_inventory_system_item(
        p_farm_id, 'trays_filled', 'صحون معبئة');

    -- ضبط الرصيد الافتتاحي مرة واحدة فقط (لا يدهس حركات لاحقة). الحارس
    -- protect_inventory_quantity يُسمح له عبر مفتاح الترانزاكشن.
    PERFORM set_config('app.allow_inventory_update', 'on', true);
    UPDATE public.inventory_items
       SET quantity = v_empty, version = version + 1, updated_at = now()
     WHERE id = v_eid AND quantity = 0;
    UPDATE public.inventory_items
       SET quantity = v_filled, version = version + 1, updated_at = now()
     WHERE id = v_fid AND quantity = 0;
    PERFORM set_config('app.allow_inventory_update', 'off', true);
END;
$$;

-- تطبيق الرصيد الافتتاحي على كل مزرعة موجودة
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT id FROM public.farms LOOP
        PERFORM public.backfill_inventory_trays(r.id);
    END LOOP;
END $$;

-- ────────────────────────────────────────────────────────────
-- (g) RLS: العامل يقرأ inventory_items لمزرعته (المدير يبقى FOR ALL)
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS inventory_items_worker_select ON public.inventory_items;
CREATE POLICY inventory_items_worker_select ON public.inventory_items
    FOR SELECT TO authenticated
    USING (
        is_system_admin()
        OR (current_user_role() = 'worker' AND farm_id = current_user_farm_id())
    );

-- ────────────────────────────────────────────────────────────
-- (h) إعادة إرسال sync_can_write / sync_can_read
--     المصدر الرسمي الحالي: 20260926000100_sync_publish_revenue_and_occ.sql
--     (ليس UNIFIED_schema.sql الأقدم — العامل يملك revenue وdispatch_requests).
--     التعديل الوحيد: إضافة inventory_items لقائمة قراءة العامل فقط.
--     (العامل لا يكتب inventory_* ولا يرى السجل ledger)
-- ────────────────────────────────────────────────────────────
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
                'dispatch_requests', 'inventory_items'
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

COMMIT;
