-- ═══════════════════════════════════════════════════════════════
-- UPGRADE_security_review_fixes.sql
-- Madjana Poultry Farm — Security Review Fixes (P0)
-- ═══════════════════════════════════════════════════════════════
-- السلامة: جميع الأوامر إضافية أو إعادة إنشاء (CREATE OR REPLACE /
-- DROP POLICY) — لا DROP TABLE، ولا DROP COLUMN، ولا حذف بيانات.
-- يُطبَّق بعد كل ملفات UNIFIED_schema.sql و UPGRADE_*.sql (الأخير).
-- ═══════════════════════════════════════════════════════════════
-- يعالج:
--   F-01  كسر عزل المداجن في `revenue` (سياسة mgr_all بلا farm_id)
--   F-02  idempotency_log بلا RLS + منح كامل لـ authenticated
--   F-03  دوال الهوية لا تحترم is_active → الحساب المعطَّل يستمر بالدخول
--   F-04  refresh_sync_checkpoint غير محمي (p_all يعيد ضبط كل المداجن)
--   F-05  REVOKE EXECUTE عام من PUBLIC/anon ثم منح انتقائي
--   F-06  إعادة تفعيل حماية العامل في auto_maintain_sync (H-3)
-- ═══════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────
-- F-01: عزل مدجنة في `revenue`
-- المشكلة (حرجة): ensure_manager_policies('revenue') أنشأت mgr_all
-- بفحص الدور فقط (بلا farm_id) → أي مدير يقرأ/يعدّل إيرادات كل المداجن.
-- (UPGRADE_p0_security_data_integrity أصلحت 4 جداول وتجاهلت revenue.)
-- ─────────────────────────────────────────────
DROP POLICY IF EXISTS mgr_all ON revenue;
DROP POLICY IF EXISTS revenue_manager_farm_scoped ON revenue;
CREATE POLICY revenue_manager_farm_scoped ON revenue
  FOR ALL
  USING (
    is_system_admin() OR
    (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
  );

-- ─────────────────────────────────────────────
-- F-02: RLS على idempotency_log
-- المشكلة (حرجة): الجدول أُنشئ بلا RLS + منح كامل، والسياسة الموجودة
-- بلا أثر → أي مستخدم مصادَق يسمّم/يمسح سجل العمليات المماثلة.
-- الإصلاح: تفعيل RLS ومنع المنح المباشر (الكتابة تتم داخلياً من دوال
-- SECURITY DEFINER تعمل بصلاحيات المالك فتمرّ حول RLS بأمان).
-- ─────────────────────────────────────────────
ALTER TABLE idempotency_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS idemp_only_owner ON idempotency_log;
REVOKE ALL ON idempotency_log FROM authenticated;
GRANT SELECT, INSERT ON idempotency_log TO service_role;

-- ─────────────────────────────────────────────
-- F-03: الحساب المعطَّل يجب ألا يمرّ عبر RLS
-- المشكلة (حرجة): current_user_role()/current_user_farm_id() لا تفحصان
-- is_active → تعطيل الحساب لا يُسقط أذوناته الفعلية.
-- الإصلاح: إرجاع NULL عندما يكون الحساب غير مفعّل، فتفشل كل الشروط
-- (role = 'manager' و farm_id = current_user_farm_id()).
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT CASE WHEN u.is_active THEN u.role::text END
    FROM public.users AS u
    WHERE u.id = auth.uid()
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.current_user_farm_id()
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT CASE WHEN u.is_active THEN u.farm_id END
    FROM public.users AS u
    WHERE u.id = auth.uid()
    LIMIT 1;
$$;

-- ─────────────────────────────────────────────
-- F-04: تحصين refresh_sync_checkpoint
-- المشكلة (حرجة): SECURITY DEFINER بلا تحقق → أي جلسة تعيد ضبط علامة
-- أي مدجنة، أو تستدعي p_all=true لمسح الجدول الزمني كاملاً.
-- الإصلاح:
--   * p_all = true → مدير النظام فقط.
--   * p_farm_id → يجب أن يكون المستخدم من تلك المدجنة (أو مديراً للنظام).
-- ملاحظة: call sites الداخلية (cleanup/compact/auto_maintain) تستدعيها
-- بصيغة المزرعة الخاصة للمستدعي، وp_all = true فقط داخل فروع
-- is_system_admin — فلا يكسر أي تدفق سحب شرعي.
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.refresh_sync_checkpoint(
    p_farm_id uuid DEFAULT NULL,
    p_all boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_f record;
BEGIN
    IF p_all THEN
        IF NOT public.is_system_admin() THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: p_all لمدير النظام فقط';
        END IF;
        FOR v_f IN SELECT id FROM public.farms LOOP
            PERFORM public.refresh_sync_checkpoint(v_f.id);
        END LOOP;
        RETURN;
    END IF;

    IF p_farm_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_ERROR: يجب تحديد مزرعة أو p_all = true';
    END IF;

    -- أي دور (worker/manager) مسموح بتحديث نقطة مزرعته فقط؛
    -- مدير النظام يحدّث أي مزرعة.
    IF NOT public.is_system_admin()
       AND public.current_user_farm_id() IS DISTINCT FROM p_farm_id
       AND NOT EXISTS (
           SELECT 1 FROM public.user_farms
           WHERE user_id = auth.uid() AND farm_id = p_farm_id
       )
    THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: هذه المزرعة ليست من مزارعك';
    END IF;

    INSERT INTO sync_checkpoint (farm_id, latest_version, purged_below, updated_at)
    SELECT
        p_farm_id,
        COALESCE((SELECT MAX(server_version) FROM sync_changes WHERE farm_id = p_farm_id), 0),
        COALESCE((SELECT MIN(server_version) FROM sync_changes WHERE farm_id = p_farm_id), 0),
        NOW()
    ON CONFLICT (farm_id) DO UPDATE SET
        latest_version = EXCLUDED.latest_version,
        purged_below   = EXCLUDED.purged_below,
        updated_at     = NOW();
END;
$$;

-- ─────────────────────────────────────────────
-- F-06: استعادة حماية العامل في auto_maintain_sync
-- ملاحظة: نسخة UPGRADE_sync_read_fix أسقطت فرع العامل (H-3) فأي سحب
-- من عامل يستدعي cleanup/compact المرفوضة على العمال → فشل سحب العامل
-- بالكامل. نعيد النسخة الآمنة: العامل يسجّل نقطة التزامن فقط ويتوقف.
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.auto_maintain_sync()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_farm      uuid;
    v_interval  interval;
    v_last      timestamptz;
BEGIN
    v_farm := public.current_user_farm_id();
    IF v_farm IS NULL THEN
        RETURN;
    END IF;

    -- العامل لا يملك صلاحية الصيانة (cleanup/compact مرفوضتان عليه)
    -- نكتفي بتسجيل نقطة التزامن وإرجاع.
    IF public.current_user_role() = 'worker' THEN
        INSERT INTO sync_checkpoint (farm_id, latest_version, purged_below, last_maintenance, updated_at)
        SELECT
            v_farm,
            COALESCE((SELECT MAX(server_version) FROM sync_changes WHERE farm_id = v_farm), 0),
            COALESCE((SELECT MIN(server_version) FROM sync_changes WHERE farm_id = v_farm), 0),
            NOW(), NOW()
        ON CONFLICT (farm_id) DO UPDATE SET
            latest_version    = EXCLUDED.latest_version,
            purged_below      = EXCLUDED.purged_below,
            last_maintenance  = NOW(),
            updated_at        = NOW();
        RETURN;
    END IF;

    v_interval := make_interval(mins => 360);

    SELECT last_maintenance INTO v_last
    FROM sync_checkpoint WHERE farm_id = v_farm;

    IF v_last IS NOT NULL AND v_last > NOW() - v_interval THEN
        RETURN;
    END IF;

    PERFORM public.cleanup_old_sync_changes(NULL, v_farm);
    PERFORM public.compact_sync_changes(v_farm);

    INSERT INTO sync_checkpoint (farm_id, latest_version, purged_below, last_maintenance, updated_at)
    SELECT
        v_farm,
        COALESCE((SELECT MAX(server_version) FROM sync_changes WHERE farm_id = v_farm), 0),
        COALESCE((SELECT MIN(server_version) FROM sync_changes WHERE farm_id = v_farm), 0),
        NOW(), NOW()
    ON CONFLICT (farm_id) DO UPDATE SET
        latest_version    = EXCLUDED.latest_version,
        purged_below      = EXCLUDED.purged_below,
        last_maintenance  = NOW(),
        updated_at        = NOW();
END;
$$;

-- ─────────────────────────────────────────────
-- F-05: سحب EXECUTE العام
-- المشكلة (حرجة): لا يوجد REVOKE في المشروع → كل دوال SECURITY DEFINER
-- مكشوفة افتراضياً لـ PUBLIC (يشمل anon/authenticated/أي دور مستقبلي).
-- الإصلاح: إلغاء التنفيذ تلقائياً ثم المنح الانتقائي للصلاحيات الفعلية:
--   * anon: فقط دوال التهيئة/الدخول (للمسار قبل تسجيل الدخول).
--   * authenticated: كل الدوال التي تستدعيها التطبيقات فعلياً + مساعدات RLS.
--   * service_role: الدوال التي قد يحتاجها السيرفر/الإدارة.
-- ملاحظة أمان إضافية: record_login_success تبقى for authenticated فقط
-- حتى لا يستطيع anon تصفير عدّاد قفل أي حساب.
-- ─────────────────────────────────────────────
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon;

-- دوال التهيئة والدخول (anon — تُستدعى قبل المصادقة)
GRANT EXECUTE ON FUNCTION public.has_system_admin() TO anon;
GRANT EXECUTE ON FUNCTION public.create_first_admin(text, text, text, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.bootstrap_create_farm_and_manager(text, text, text, text, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.check_login_allowed(text) TO anon;
GRANT EXECUTE ON FUNCTION public.find_user_by_phone(text) TO anon;
GRANT EXECUTE ON FUNCTION public.record_login_failure(text) TO anon;
GRANT EXECUTE ON FUNCTION public.throttle_exceeded(text, int, int) TO anon;
GRANT EXECUTE ON FUNCTION public.is_system_admin() TO anon;
GRANT EXECUTE ON FUNCTION public.app_password_from_pin(text) TO anon;
GRANT EXECUTE ON FUNCTION public.app_user_email(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.current_user_role() TO anon;
GRANT EXECUTE ON FUNCTION public.current_user_farm_id() TO anon;

-- مساعدات RLS والدخول (authenticated)
GRANT EXECUTE ON FUNCTION public.current_user_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_farm_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_farm_ids() TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_farms_with_names() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_active_farm(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_system_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.find_user_by_phone(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_login_allowed(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_login_failure(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_login_success(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.throttle_exceeded(text, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_password_from_pin(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_user_email(uuid) TO authenticated;

-- دالة المزامنة والمحافظة (authenticated + service_role)
GRANT EXECUTE ON FUNCTION public.sync_records_batch(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pull_remote_changes(uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_live_ids(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_live_exists(text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_old_sync_changes(int, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.compact_sync_changes(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.auto_maintain_sync() TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_sync_checkpoint(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_can_write(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_can_read(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_tombstone_after_delete() TO authenticated;

GRANT EXECUTE ON FUNCTION public.sync_records_batch(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.pull_remote_changes(uuid, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.sync_live_ids(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.sync_live_exists(text, uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_old_sync_changes(int, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.compact_sync_changes(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.auto_maintain_sync() TO service_role;
GRANT EXECUTE ON FUNCTION public.refresh_sync_checkpoint(uuid, boolean) TO service_role;

-- دوال إدارة المستخدمين والمزارع (authenticated — تحقّق الدور داخلياً)
GRANT EXECUTE ON FUNCTION public.admin_create_user(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_user(text, text, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reset_pin(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_sync_health(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_select_all_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_select_all_farms() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_select_all_users_with_farms() TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_farm_with_manager(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_farm(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_assign_user_to_farm(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_unassign_user_from_farm(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_farm_users(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bootstrap_create_farm_and_manager(text, text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_system_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_first_admin(text, text, text, text, text) TO authenticated;

-- سجل تدقيق يتيح للخدمات قراءة idempotency عند الحاجة
GRANT SELECT ON idempotency_log TO service_role;

COMMIT;