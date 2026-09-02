-- ============================================================
-- Migration 20260902_002: RLS system_admin bypass
-- القاعدة: system_admin → كل المداجن | manager → فلدي فقط | worker → فلدي فقط
-- ============================================================

-- ============================================================
-- a) دوال سياسة موحدة: تُستخدم عبر ensure_operational_policies
-- ============================================================

-- تأكد أن is_system_admin() متاحة (أُنشئت في migration 001)

-- ============================================================
-- b) farms: system_admin = كل شيء، manager = فلدي فقط
-- ============================================================
DROP POLICY IF EXISTS farms_select_own ON farms;
CREATE POLICY farms_select_own ON farms
    FOR SELECT TO authenticated
    USING (
        is_system_admin()
        OR id = NULLIF(auth.jwt() -> 'user_metadata' ->> 'farm_id', '')::uuid
    );

DROP POLICY IF EXISTS farms_insert_manager ON farms;
CREATE POLICY farms_insert_manager ON farms
    FOR INSERT TO authenticated
    WITH CHECK (is_system_admin());

DROP POLICY IF EXISTS farms_update_manager ON farms;
CREATE POLICY farms_update_manager ON farms
    FOR UPDATE TO authenticated
    USING (is_system_admin() OR current_user_role() = 'manager')
    WITH CHECK (is_system_admin() OR current_user_role() = 'manager');

DROP POLICY IF EXISTS farms_delete_manager ON farms;
CREATE POLICY farms_delete_manager ON farms
    FOR DELETE TO authenticated
    USING (is_system_admin());

-- ============================================================
-- c) users: system_admin = كل المستخدمين، manager = مستخدمي مزرعته
-- ============================================================
DROP POLICY IF EXISTS users_select_self ON users;
CREATE POLICY users_select_self ON users
    FOR SELECT TO authenticated
    USING (
        id = auth.uid()
        OR is_system_admin()
        OR (
            (auth.jwt() -> 'user_metadata' ->> 'role') = 'manager'
            AND farm_id = NULLIF(auth.jwt() -> 'user_metadata' ->> 'farm_id', '')::uuid
        )
    );

DROP POLICY IF EXISTS users_select_same_farm ON users;
-- (تم دمجها أعلاه في users_select_self — لا حاجة لسياسة منفصلة)

DROP POLICY IF EXISTS users_update_self ON users;
CREATE POLICY users_update_self ON users
    FOR UPDATE TO authenticated
    USING (
        id = auth.uid()
        OR is_system_admin()
        OR current_user_role() = 'manager'
    )
    WITH CHECK (
        id = auth.uid()
        OR is_system_admin()
        OR (
            current_user_role() = 'manager'
            AND farm_id = NULLIF(auth.jwt() -> 'user_metadata' ->> 'farm_id', '')::uuid
        )
    );

-- ============================================================
-- d) الجداول التشغيلية: system_admin يتجاوز عزل farm_id
-- ============================================================
CREATE OR REPLACE FUNCTION public.ensure_operational_policies(p_table name)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    EXECUTE format('DROP POLICY IF EXISTS op_select ON %I', p_table);
    EXECUTE format('DROP POLICY IF EXISTS op_insert ON %I', p_table);
    EXECUTE format('DROP POLICY IF EXISTS op_update ON %I', p_table);
    EXECUTE format('DROP POLICY IF EXISTS op_delete ON %I', p_table);
    EXECUTE format('CREATE POLICY op_select ON %I FOR SELECT TO authenticated USING (is_system_admin() OR farm_id = current_user_farm_id())', p_table);
    EXECUTE format('CREATE POLICY op_insert ON %I FOR INSERT TO authenticated WITH CHECK (is_system_admin() OR farm_id = current_user_farm_id())', p_table);
    EXECUTE format('CREATE POLICY op_update ON %I FOR UPDATE TO authenticated USING (is_system_admin() OR farm_id = current_user_farm_id()) WITH CHECK (is_system_admin() OR farm_id = current_user_farm_id())', p_table);
    EXECUTE format('CREATE POLICY op_delete ON %I FOR DELETE TO authenticated USING ((is_system_admin() OR farm_id = current_user_farm_id()) AND (is_system_admin() OR current_user_role() = ''manager''))', p_table);
END;
$$;

SELECT public.ensure_operational_policies('flocks');
SELECT public.ensure_operational_policies('customers');
SELECT public.ensure_operational_policies('egg_production');
SELECT public.ensure_operational_policies('mortality');
SELECT public.ensure_operational_policies('feed_consumption');
SELECT public.ensure_operational_policies('feed_received');
SELECT public.ensure_operational_policies('egg_dispatch');
SELECT public.ensure_operational_policies('medications');

-- ============================================================
-- e) الجداول المالية: system_admin + manager
-- ============================================================
CREATE OR REPLACE FUNCTION public.ensure_manager_policies(p_table name)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    EXECUTE format('DROP POLICY IF EXISTS mgr_all ON %I', p_table);
    EXECUTE format('CREATE POLICY mgr_all ON %I FOR ALL TO authenticated USING (is_system_admin() OR current_user_role() = ''manager'') WITH CHECK (is_system_admin() OR current_user_role() = ''manager'')', p_table);
END;
$$;

SELECT public.ensure_manager_policies('payments');
SELECT public.ensure_manager_policies('expenses');
SELECT public.ensure_manager_policies('opening_balances');
SELECT public.ensure_manager_policies('inventory_items');
SELECT public.ensure_manager_policies('audit_log');

-- inventory_transactions
DROP POLICY IF EXISTS mgr_tx ON inventory_transactions;
CREATE POLICY mgr_tx ON inventory_transactions
    FOR ALL TO authenticated
    USING (
        is_system_admin()
        OR (
            current_user_role() = 'manager'
            AND item_id IN (SELECT i.id FROM inventory_items i WHERE i.farm_id = current_user_farm_id())
        )
    )
    WITH CHECK (
        is_system_admin()
        OR (
            current_user_role() = 'manager'
            AND item_id IN (SELECT i.id FROM inventory_items i WHERE i.farm_id = current_user_farm_id())
        )
    );

-- ============================================================
-- f) medicines_catalog
-- ============================================================
DROP POLICY IF EXISTS catalog_select ON medicines_catalog;
CREATE POLICY catalog_select ON medicines_catalog
    FOR SELECT TO authenticated
    USING (true);

DROP POLICY IF EXISTS catalog_manager ON medicines_catalog;
CREATE POLICY catalog_manager ON medicines_catalog
    FOR ALL TO authenticated
    USING (is_system_admin() OR current_user_role() = 'manager')
    WITH CHECK (is_system_admin() OR current_user_role() = 'manager');

-- ============================================================
-- g) app_settings
-- ============================================================
DROP POLICY IF EXISTS app_settings_manager_select ON app_settings;
CREATE POLICY app_settings_manager_select ON app_settings
    FOR SELECT TO authenticated
    USING (is_system_admin() OR current_user_role() = 'manager');

DROP POLICY IF EXISTS app_settings_manager_write ON app_settings;
CREATE POLICY app_settings_manager_write ON app_settings
    FOR INSERT TO authenticated
    WITH CHECK (is_system_admin() OR current_user_role() = 'manager');

DROP POLICY IF EXISTS app_settings_manager_update ON app_settings;
CREATE POLICY app_settings_manager_update ON app_settings
    FOR UPDATE TO authenticated
    USING (is_system_admin() OR current_user_role() = 'manager')
    WITH CHECK (is_system_admin() OR current_user_role() = 'manager');

-- ============================================================
-- h) app_notifications
-- ============================================================
DROP POLICY IF EXISTS notif_read ON app_notifications;
CREATE POLICY notif_read ON app_notifications
    FOR SELECT TO authenticated
    USING (is_system_admin() OR farm_id = current_user_farm_id());

DROP POLICY IF EXISTS notif_manager ON app_notifications;
CREATE POLICY notif_manager ON app_notifications
    FOR ALL TO authenticated
    USING (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    )
    WITH CHECK (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    );

-- ============================================================
-- i) dispatch_requests
-- ============================================================
DROP POLICY IF EXISTS dreq_select ON dispatch_requests;
CREATE POLICY dreq_select ON dispatch_requests
    FOR SELECT TO authenticated
    USING (is_system_admin() OR farm_id = current_user_farm_id());

DROP POLICY IF EXISTS dreq_insert ON dispatch_requests;
CREATE POLICY dreq_insert ON dispatch_requests
    FOR INSERT TO authenticated
    WITH CHECK (is_system_admin() OR farm_id = current_user_farm_id());

DROP POLICY IF EXISTS dreq_manager ON dispatch_requests;
CREATE POLICY dreq_manager ON dispatch_requests
    FOR UPDATE TO authenticated
    USING (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    )
    WITH CHECK (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    );

DROP POLICY IF EXISTS dreq_manager_delete ON dispatch_requests;
CREATE POLICY dreq_manager_delete ON dispatch_requests
    FOR DELETE TO authenticated
    USING (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    );

-- ============================================================
-- j) sync_changes: system_admin يستطيع قراءة كل التغييرات
-- ============================================================
DROP POLICY IF EXISTS sync_changes_select ON sync_changes;
CREATE POLICY sync_changes_select ON sync_changes
    FOR SELECT TO authenticated
    USING (
        is_system_admin()
        OR farm_id = current_user_farm_id()
    );

-- ============================================================
-- k) audit_log: system_admin يرى كل شيء
-- ============================================================
DROP POLICY IF EXISTS audit_select_manager ON audit_log;
CREATE POLICY audit_select_manager ON audit_log
    FOR SELECT TO authenticated
    USING (
        is_system_admin()
        OR (
            farm_id = current_user_farm_id()
            AND current_user_role() = 'manager'
        )
    );

DROP POLICY IF EXISTS audit_insert_manager ON audit_log;
CREATE POLICY audit_insert_manager ON audit_log
    FOR INSERT TO authenticated
    WITH CHECK (
        is_system_admin()
        OR (
            farm_id = current_user_farm_id()
            AND current_user_role() = 'manager'
        )
    );

-- ============================================================
-- l) GRANT للدوال الجديدة
-- ============================================================
GRANT EXECUTE ON FUNCTION public.is_system_admin() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_farm_with_manager(text, text, text, text, text) TO authenticated;

-- ============================================================
-- m)_admin_select_all_users: RPC لجلب كل المستخدمين (لـ system_admin)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_select_all_users()
RETURNS SETOF users
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    -- فقط system_admin يمكنه جلب كل المستخدمين
    SELECT u.*
    FROM public.users u
    WHERE public.is_system_admin()
    ORDER BY u.created_at;
$$;

GRANT EXECUTE ON FUNCTION public.admin_select_all_users() TO authenticated;

-- admin_select_all_farms: RPC لجلب كل المداجن (لـ system_admin)
CREATE OR REPLACE FUNCTION public.admin_select_all_farms()
RETURNS SETOF farms
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT f.*
    FROM public.farms f
    WHERE public.is_system_admin()
    ORDER BY f.created_at;
$$;

GRANT EXECUTE ON FUNCTION public.admin_select_all_farms() TO authenticated;
