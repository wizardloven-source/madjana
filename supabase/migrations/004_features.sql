-- ============================================================
-- 004 (v2): ميزات جديدة
-- 1) app_notifications: إشعارات المدير الدائمة/المؤقتة للمداجن
-- 2) dispatch_requests: طلبات العامل عند تجاوز مخزون البيض
-- 3) العنابر: عدد عنابر القطيع + رقم العنبر في سجل البيض
--
-- ملاحظة مهمة: السياسات لا تستخدم current_user_farm_id()
-- لأن نسخاً قديمة منها قد تُرجع uuid؛ كل شيء inline مع ::text
-- آمن لإعادة التنفيذ بالكامل
-- ============================================================

-- ------------------------------------------------------------
-- 1) الإشعارات
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS app_notifications (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id       text NOT NULL,
    flock_id      text,
    title         text NOT NULL,
    body          text,
    level         text NOT NULL DEFAULT 'info',
    is_persistent boolean NOT NULL DEFAULT false,
    is_active     boolean NOT NULL DEFAULT true,
    created_by    text,
    created_at    timestamptz NOT NULL DEFAULT NOW()
);

ALTER TABLE app_notifications ENABLE ROW LEVEL SECURITY;

-- قراءة: أي مستخدم مدجنته مطابقة
DROP POLICY IF EXISTS notif_farm_read ON app_notifications;
CREATE POLICY notif_farm_read ON app_notifications
    FOR SELECT TO authenticated
    USING (
        farm_id = (
            SELECT u.farm_id FROM public.users u
            WHERE u.id = (SELECT auth.uid())::text
            LIMIT 1
        )
    );

-- كتابة كاملة: للمدير على مدجنته فقط
DROP POLICY IF EXISTS notif_manager_write ON app_notifications;
CREATE POLICY notif_manager_write ON app_notifications
    FOR ALL TO authenticated
    USING (
        (
            SELECT u.role FROM public.users u
            WHERE u.id = (SELECT auth.uid())::text
            LIMIT 1
        ) = 'manager'
        AND farm_id = (
            SELECT u.farm_id FROM public.users u
            WHERE u.id = (SELECT auth.uid())::text
            LIMIT 1
        )
    )
    WITH CHECK (
        (
            SELECT u.role FROM public.users u
            WHERE u.id = (SELECT auth.uid())::text
            LIMIT 1
        ) = 'manager'
        AND farm_id = (
            SELECT u.farm_id FROM public.users u
            WHERE u.id = (SELECT auth.uid())::text
            LIMIT 1
        )
    );

GRANT SELECT ON app_notifications TO authenticated;
GRANT INSERT, UPDATE, DELETE ON app_notifications TO authenticated;

-- ------------------------------------------------------------
-- 2) طلبات تخريج تتجاوز المخزون (بحاجة موافقة المدير)
-- status: pending | approved | rejected
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dispatch_requests (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id      text NOT NULL,
    flock_id     text,
    customer_id  text,
    cartons      int  NOT NULL DEFAULT 0,
    trays        int  NOT NULL DEFAULT 0,
    total_eggs   int  NOT NULL DEFAULT 0,
    stock_eggs   int  NOT NULL DEFAULT 0,
    status       text NOT NULL DEFAULT 'pending',
    worker_id    text,
    created_at   timestamptz NOT NULL DEFAULT NOW(),
    decided_at   timestamptz,
    decided_by   text
);

ALTER TABLE dispatch_requests ENABLE ROW LEVEL SECURITY;

-- قراءة: نفس المدجنة
DROP POLICY IF EXISTS dreq_farm_read ON dispatch_requests;
CREATE POLICY dreq_farm_read ON dispatch_requests
    FOR SELECT TO authenticated
    USING (
        farm_id = (
            SELECT u.farm_id FROM public.users u
            WHERE u.id = (SELECT auth.uid())::text
            LIMIT 1
        )
    );

-- إدخال: أي عامل على مدجنته (الطلب دائماً من عامل)
DROP POLICY IF EXISTS dreq_worker_insert ON dispatch_requests;
CREATE POLICY dreq_worker_insert ON dispatch_requests
    FOR INSERT TO authenticated
    WITH CHECK (
        farm_id = (
            SELECT u.farm_id FROM public.users u
            WHERE u.id = (SELECT auth.uid())::text
            LIMIT 1
        )
    );

-- تحديث: للمدير فقط (اعتماد/رفض)
DROP POLICY IF EXISTS dreq_manager_update ON dispatch_requests;
CREATE POLICY dreq_manager_update ON dispatch_requests
    FOR UPDATE TO authenticated
    USING (
        (
            SELECT u.role FROM public.users u
            WHERE u.id = (SELECT auth.uid())::text
            LIMIT 1
        ) = 'manager'
        AND farm_id = (
            SELECT u.farm_id FROM public.users u
            WHERE u.id = (SELECT auth.uid())::text
            LIMIT 1
        )
    );

-- ------------------------------------------------------------
-- 3) العنابر
-- ------------------------------------------------------------
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS sections_count int NOT NULL DEFAULT 1;
ALTER TABLE egg_production ADD COLUMN IF NOT EXISTS section_no int;

-- إعادة تحميل مخطط PostgREST حتى يتعرف على الجداول والأعمدة الجديدة
NOTIFY pgrst, 'reload schema';
