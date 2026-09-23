-- ============================================================
-- UPGRADE / REPAIR: استعادة زبون ناقص أُزيل محلياً (سامر عربش)
-- ------------------------------------------------------------
-- السبب الجذري: sync_live_ids سابقاً كان يجلب فقط أرقام ids
--   "المزرعة المعنية"، فأي زبون عام (is_global) أو زبون سقط
--   يوماً ما من استجابة REST كان التطبيق يحذفه من التخزين
--   المحلي عبر _reconcileServerDeleted، فيختفي من كل القوائم.
--     يُعالج المسبب بشكل دائم بملف:
--         UPGRADE_sync_live_ids_is_global.sql
--     أما هذا الملف فيصلح "البيانات الحالية" على الخادم:
--         1) يُشخّص صف الزبون af8c4dea-6937-45d4-a95b-ee63427ace7a
--         2) يُلغي حذفه الناعم / يوحد بياناته لمزرعة "الجرار"
--         3) يدفع sync_changes (INSERT) حتى تجلبه كل الأجهزة
-- ملاحظة: egg_dispatch.customer_id هو FK إلزامي نحو customers،
--   لذا أي تخريجة موجودة تضمن وجود صف الزبون (ربما محذوف ناعماً)
--   ولا حاجة لـ INSERT جديد — يكفي رفع deleted_at.
-- ============================================================

DO $$
DECLARE
    v_customer_id CONSTANT uuid := 'af8c4dea-6937-45d4-a95b-ee63427ace7a';
    v_farm_id     CONSTANT uuid := '12141b73-ebee-4ab0-be31-80195b759303';
    v_cust        public.customers%ROWTYPE;
    v_dispatch_count bigint;
    v_payload     jsonb;
BEGIN
    -- (1) تشخيص قبل الإصلاح
    SELECT * INTO v_cust FROM public.customers WHERE id = v_customer_id;
    SELECT COUNT(*) INTO v_dispatch_count
        FROM public.egg_dispatch
        WHERE customer_id = v_customer_id AND deleted_at IS NULL;

    RAISE NOTICE 'customer % -> dispatch_count=%', v_customer_id, v_dispatch_count;
    IF v_cust.id IS NULL THEN
        RAISE NOTICE 'STATUS: customer MISSING entirely';
    ELSIF v_cust.deleted_at IS NOT NULL THEN
        RAISE NOTICE 'STATUS: customer SOFT-DELETED deleted_at=%', v_cust.deleted_at;
    ELSE
        RAISE NOTICE 'STATUS: customer EXISTS farm_id=% is_global=% name=%',
            v_cust.farm_id, v_cust.is_global, v_cust.name;
    END IF;

    -- (2) الإصلاح: توحيد بياناته وإلغاء الحذف الناعم وجعله عاماً بحسب الدور
    UPDATE public.customers
    SET farm_id    = v_farm_id,
        is_global  = TRUE,
        deleted_at = NULL,
        updated_at = NOW()
    WHERE id = v_customer_id;
    RAISE NOTICE 'ACTION: customer un-deleted / re-homed farm_id=% is_global=true', v_farm_id;

    -- إن كان مفقوداً كلياً (نادر بفعل FK)، أعده من المعطيات المعروفة
    IF NOT FOUND THEN
        INSERT INTO public.customers (id, name, phone, farm_id, is_global, notes, created_at, updated_at, deleted_at)
        VALUES (v_customer_id, 'سامر عربش', '', v_farm_id, TRUE,
                'تمت استعادته عبر إصلاح المزامنة', NOW(), NOW(), NULL)
        ON CONFLICT (id) DO NOTHING;
        RAISE NOTICE 'ACTION: customer INSERTED from known data';
    END IF;

    -- (3) دفع sync_changes (INSERT) لمزرعة الجرار حتى تُسحب كل الأجهزة
    SELECT row_to_json(c)::jsonb INTO v_payload
    FROM public.customers c WHERE c.id = v_customer_id;

    INSERT INTO public.sync_changes (table_name, record_id, operation, farm_id, device_id, user_id, payload)
    VALUES ('customers', v_customer_id, 'INSERT', v_farm_id, 'repair-script', NULL, v_payload);
    RAISE NOTICE 'ACTION: sync_changes pushed for customers/%', v_customer_id;
END $$;