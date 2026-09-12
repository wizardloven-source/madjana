-- ============================================================================
-- ترقية: منع إحياء أي سجلات محذوفة في الأجهزة + توثيق الحذف المباشر
--
-- ملاحظة: ملف إضافي (additive) - لا يمسح أي بيانات. يُطبَّق في محرر SQL.
--
-- المشكلة:
--  1) الحذف عبر التطبيق كان يُسجَّل في sync_changes (tombstone) فيصل لكل الجهات.
--     لكن الحذف المباشر من الجداول (SQL Editor / Table Editor) لا يُسجَّل،
--     فيبقى صف INSERT القديم في sync_changes. عند أي سحب كامل من الإصدار 0
--     (جهاز جديد / إعادة مزامنة) يعيد الجهاز بناء السجل المحذوف → يظهر مجدداً
--     في الموبايل والديسكتوب رغم أنه محذوف من القاعدة.
--  2) صيانة cleanup_old_sync_changes (بعد 30 يوم) تمسح التوابيت (تسجيلات DELETE)
--     بينما تبقى صفوف INSERT، فيتعمق نفس الخلل مع الزمن.
--
-- الحل (هنا):
--  A) trigger على كل جدول قابل للمزامنة: أي حذف مباشر (SQL/REST) يُسجَّل تلقائياً
--     كـ DELETE في sync_changes → تصل "كهذا" لكل الأجهزة وتحذف محلياً.
--  B) تعديل pull_remote_changes: لا يُرسل INSERT/UPDATE لتسجيل لم يعد موجوداً
--     فعلياً في القاعدة (id حي + deleted_at IS NULL). هذا يمنع إحياء أي سجل
--     محذوف مهما كان تاريخ التوابيت ناقصاً — وبأثر فوري على الجهاز الحالي.
--
-- ملاحظة فنية: عند الحذف عبر التطبيق (sync_records_batch) يُفعَّل
-- set_config('app.skip_sync_trigger','on') فلا يُسجَّل الحذف مرتين.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) دالة التحقق: هل السجل ما زال حياً في القاعدة؟ (تتسامح مع أخطاء الأعمدة)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_live_exists(p_table text, p_id uuid, p_farm uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result boolean;
BEGIN
    IF p_table NOT IN (
        'flocks','egg_production','mortality','feed_consumption','feed_received',
        'egg_dispatch','medications','customers','expenses','inventory_items',
        'inventory_transactions','opening_balances','payments'
    ) THEN
        RETURN false;
    END IF;
    BEGIN
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM %I WHERE id = $1 AND farm_id = $2 AND deleted_at IS NULL)',
            p_table
        ) INTO v_result USING p_id, p_farm;
        RETURN v_result;
    EXCEPTION WHEN OTHERS THEN
        -- لا نمنع السحب بسبب مشكلة عمود/جدول: نعود true (نتيح السجل للسحب)
        RETURN true;
    END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_live_exists(text, uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) توثيق الحذف المباشر: trigger بعد DELETE على كل جدول قابل للمزامنة
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_tombstone_after_delete()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF current_setting('app.skip_sync_trigger', true) = 'on' THEN
        RETURN OLD;
    END IF;

    IF OLD.farm_id IS NULL THEN
        RETURN OLD;
    END IF;

    BEGIN
        INSERT INTO public.sync_changes (table_name, record_id, operation, farm_id, user_id, payload, device_id)
        VALUES (
            TG_TABLE_NAME,
            OLD.id,
            'DELETE',
            OLD.farm_id,
            auth.uid(),
            jsonb_build_object('id', OLD.id),
            NULLIF(current_setting('app.device_id', true), '')
        );
    EXCEPTION WHEN OTHERS THEN
        NULL; -- توثيق الحذف غير حرج للعملية نفسها
    END;

    RETURN OLD;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_tombstone_after_delete() TO authenticated;

-- إنشاء trigger لكل جدول (DROP+CREATE لضمان التطبيق المتكرر بأمان)
DROP TRIGGER IF EXISTS trg_sync_tombstone_flocks ON public.flocks;
CREATE TRIGGER trg_sync_tombstone_flocks AFTER DELETE ON public.flocks
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS trg_sync_tombstone_egg_production ON public.egg_production;
CREATE TRIGGER trg_sync_tombstone_egg_production AFTER DELETE ON public.egg_production
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS trg_sync_tombstone_mortality ON public.mortality;
CREATE TRIGGER trg_sync_tombstone_mortality AFTER DELETE ON public.mortality
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS trg_sync_tombstone_feed_consumption ON public.feed_consumption;
CREATE TRIGGER trg_sync_tombstone_feed_consumption AFTER DELETE ON public.feed_consumption
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS trg_sync_tombstone_feed_received ON public.feed_received;
CREATE TRIGGER trg_sync_tombstone_feed_received AFTER DELETE ON public.feed_received
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS trg_sync_tombstone_egg_dispatch ON public.egg_dispatch;
CREATE TRIGGER trg_sync_tombstone_egg_dispatch AFTER DELETE ON public.egg_dispatch
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS trg_sync_tombstone_medications ON public.medications;
CREATE TRIGGER trg_sync_tombstone_medications AFTER DELETE ON public.medications
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS trg_sync_tombstone_customers ON public.customers;
CREATE TRIGGER trg_sync_tombstone_customers AFTER DELETE ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS trg_sync_tombstone_expenses ON public.expenses;
CREATE TRIGGER trg_sync_tombstone_expenses AFTER DELETE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS trg_sync_tombstone_inventory_items ON public.inventory_items;
CREATE TRIGGER trg_sync_tombstone_inventory_items AFTER DELETE ON public.inventory_items
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS trg_sync_tombstone_inventory_transactions ON public.inventory_transactions;
CREATE TRIGGER trg_sync_tombstone_inventory_transactions AFTER DELETE ON public.inventory_transactions
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS trg_sync_tombstone_opening_balances ON public.opening_balances;
CREATE TRIGGER trg_sync_tombstone_opening_balances AFTER DELETE ON public.opening_balances
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS trg_sync_tombstone_payments ON public.payments;
CREATE TRIGGER trg_sync_tombstone_payments AFTER DELETE ON public.payments
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

-- ---------------------------------------------------------------------------
-- 3) سحب التغييرات مع فحص "التسجيل ما زال حياً في القاعدة":
--    لا تُرسل INSERT/UPDATE لمُعرّف محذوف فعلياً، فيستحيل إحياؤه في أي جهاز.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pull_remote_changes(
    p_farm_id uuid,
    p_from_version bigint DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role     text;
    v_latest   bigint;
    v_min_keep bigint;
    v_changes  jsonb;
    v_operational_only boolean := false;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: غير مسجل الدخول';
    END IF;

    IF NOT public.is_system_admin() THEN
        SELECT public.current_user_role() INTO v_role;
        IF v_role NOT IN ('manager', 'worker') THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: دور غير مصرح بسحب المزامنة';
        END IF;
        IF p_farm_id IS DISTINCT FROM public.current_user_farm_id() THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: مزرعة غير مصرح بها';
        END IF;
        IF v_role = 'worker' THEN
            v_operational_only := true;
        END IF;
    END IF;

    PERFORM public.auto_maintain_sync();

    SELECT latest_version, purged_below INTO v_latest, v_min_keep
    FROM sync_checkpoint WHERE farm_id = p_farm_id;

    IF v_latest IS NULL THEN
        SELECT COALESCE(MAX(server_version), 0), COALESCE(MIN(server_version), 0)
            INTO v_latest, v_min_keep
        FROM sync_changes WHERE farm_id = p_farm_id;
        IF v_min_keep = 0 THEN v_min_keep := v_latest; END IF;
        INSERT INTO sync_checkpoint (farm_id, latest_version, purged_below, updated_at)
        VALUES (p_farm_id, v_latest, v_min_keep, NOW())
        ON CONFLICT (farm_id) DO UPDATE SET
            latest_version = EXCLUDED.latest_version,
            purged_below   = EXCLUDED.purged_below,
            updated_at     = NOW();
    END IF;

    IF v_operational_only THEN
        SELECT jsonb_agg(jsonb_build_object(
            'table_name', sc.table_name,
            'record_id', sc.record_id,
            'operation', sc.operation,
            'payload', sc.payload,
            'server_version', sc.server_version,
            'created_at', sc.created_at
        ) ORDER BY sc.server_version ASC) INTO v_changes
        FROM sync_changes sc
        WHERE sc.farm_id = p_farm_id
          AND public.sync_can_read('worker', sc.table_name)
          AND sc.server_version > p_from_version
          AND (sc.operation = 'DELETE'
               OR public.sync_live_exists(sc.table_name, sc.record_id, sc.farm_id));

        SELECT COALESCE(MAX(server_version), p_from_version) INTO v_latest
        FROM sync_changes
        WHERE farm_id = p_farm_id
          AND public.sync_can_read('worker', table_name)
          AND server_version > p_from_version;

        SELECT COALESCE(MIN(server_version), v_latest) INTO v_min_keep
        FROM sync_changes
        WHERE farm_id = p_farm_id
          AND public.sync_can_read('worker', table_name);
    ELSE
        SELECT jsonb_agg(jsonb_build_object(
            'table_name', sc.table_name,
            'record_id', sc.record_id,
            'operation', sc.operation,
            'payload', sc.payload,
            'server_version', sc.server_version,
            'created_at', sc.created_at
        ) ORDER BY sc.server_version ASC) INTO v_changes
        FROM sync_changes sc
        WHERE sc.farm_id = p_farm_id
          AND sc.server_version > p_from_version
          AND (sc.operation = 'DELETE'
               OR public.sync_live_exists(sc.table_name, sc.record_id, sc.farm_id));
    END IF;

    IF p_from_version > 0 AND p_from_version < v_min_keep THEN
        RETURN jsonb_build_object(
            'resync_required', true,
            'message', 'بيانات الجهاز أقدم من فترة الاحتفاظ، يلزم إعادة مزامنة كاملة',
            'latest_version', v_latest
        );
    END IF;

    RETURN jsonb_build_object(
        'resync_required', false,
        'latest_version', v_latest,
        'changes', COALESCE(v_changes, '[]'::jsonb)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.pull_remote_changes(uuid, bigint) TO authenticated;