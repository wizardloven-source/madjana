-- ============================================================================
--  p0_role_permissions_test.sql
--  خطة W5-M16: role_permissions + user_permissions + has_capability().
--  قرار M16: جدول + دالة فحسب؛ إعادة كتابة سياسات RLS الفعلية = W6.
-- ============================================================================
BEGIN;

CREATE SCHEMA IF NOT EXISTS tests;
CREATE OR REPLACE FUNCTION tests.set_user(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config('request.jwt.claims',
        jsonb_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
END;
$$;
CREATE OR REPLACE FUNCTION tests.assert(p_label text, p_cond boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_cond THEN RAISE NOTICE 'PASS [%] %', p_label, p_detail;
    ELSE RAISE EXCEPTION 'FAIL [%] %', p_label, p_detail; END IF;
END;
$$;

DO $$
DECLARE v_super boolean; v_bypass boolean;
BEGIN
    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass FROM pg_roles WHERE rolname = current_user;
    IF v_super OR v_bypass THEN RAISE EXCEPTION 'ABORT: run as test_runner'; END IF;
END $$;

DO $s$
DECLARE
    v_admin   uuid := '00000000-0000-0000-0000-00000000000a';
    v_worker  uuid := '00000000-0000-0000-0000-00000000000b';
    v_sys     uuid := '00000000-0000-0000-0000-00000000000e';
    v_farm    uuid := '00000000-0000-0000-0000-000000000001';
    v_farmb   uuid := '00000000-0000-0000-0000-000000000002';
    v_n       int;
    v_cap     boolean;
BEGIN
    PERFORM tests.assert('M16: الجدولان موجودان',
        to_regclass('public.role_permissions') IS NOT NULL
        AND to_regclass('public.user_permissions') IS NOT NULL, '');
    PERFORM tests.assert('M16: has_capability() حية، SECURITY DEFINER، STABLE',
        (SELECT count(*) FROM pg_proc WHERE proname='has_capability'
          AND prosecdef AND provolatile='s') = 1, '');
    PERFORM tests.assert('M16: ADMIN-only RLS على الجدولين',
        (SELECT count(*) FROM pg_policies
          WHERE schemaname='public' AND tablename IN ('role_permissions','user_permissions')) >= 2, '');
    PERFORM tests.assert('M16: anon بلا EXECUTE',
        NOT has_function_privilege('anon', 'public.has_capability(uuid,text,uuid)', 'EXECUTE'), '');

    -- الرفض الافتراضي: لا يوجد أي إذن = FALSE مهما كان الدور
    v_cap := public.has_capability(v_worker, 'view_costs', v_farm);
    PERFORM tests.assert('M16: worker بلا إعدادات = FALSE',
        NOT v_cap, '');
    v_cap := public.has_capability(v_sys, 'anything', v_farm);
    PERFORM tests.assert('M16: system_admin بلا إعدادات أيضاً = FALSE (لا عبور سريع)',
        NOT v_cap, '');
    v_cap := public.has_capability(v_admin, 'view_costs', v_farm);
    PERFORM tests.assert('M16: manager بلا إعدادات = FALSE',
        NOT v_cap, '');

    -- نحوّل دور المدير فقط عبر صف عام
    PERFORM tests.set_user(v_sys);
    INSERT INTO public.role_permissions (role, capability, is_enabled, farm_id, granted_by)
    VALUES ('manager', 'view_costs', true, NULL, v_sys);
    INSERT INTO public.role_permissions (role, capability, is_enabled, farm_id, granted_by)
    VALUES ('manager', 'invoice_approve', true, v_farmb, v_sys);

    v_cap := public.has_capability(v_admin, 'view_costs', v_farm);
    PERFORM tests.assert('M16: المدير يملك view_costs عبر الإعداد العام',
        v_cap, '');
    v_cap := public.has_capability(v_worker, 'view_costs', v_farm);
    PERFORM tests.assert('M16: العامل لا يرث قدرة المدير',
        NOT v_cap, '');
    v_cap := public.has_capability(v_admin, 'invoice_approve', v_farm);
    PERFORM tests.assert('M16: قدرة مزرعة B لا تسري على مزرعة A',
        NOT v_cap, '');

    -- التفصيلية: user_permissions تغلّب أي شيء
    PERFORM tests.set_user(v_sys);
    INSERT INTO public.user_permissions (user_id, farm_id, permission_key, permission_value, granted_by)
    VALUES (v_worker, v_farm, 'view_costs', false, v_sys);
    v_cap := public.has_capability(v_worker, 'view_costs', v_farm);
    PERFORM tests.assert('M16: رفض صريح على العامل يغلب الجدول العام',
        NOT v_cap, '');
    DELETE FROM public.user_permissions WHERE user_id=v_worker AND farm_id=v_farm;

    INSERT INTO public.user_permissions (user_id, farm_id, permission_key, permission_value, granted_by)
    VALUES (v_worker, v_farm, 'view_own_records', true, v_sys);
    v_cap := public.has_capability(v_worker, 'view_own_records', v_farm);
    PERFORM tests.assert('M16: سماح صريح للعامل يغلب غياب الصف العام',
        v_cap, '');

    -- رفض الكتابة لغير ADMIN (مثال: محاولة مدير)
    PERFORM tests.set_user(v_admin);
    BEGIN
        INSERT INTO public.role_permissions (role, capability) VALUES ('worker','x');
        PERFORM tests.assert('M16: غير ADMIN لا يكتب', false, 'كُتب بواسطة مدير');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M16: غير ADMIN لا يكتب', true, SQLERRM);
    END;

    -- key مقابل farm_id الفارغ والتفرّد
    PERFORM tests.set_user(v_sys);
    BEGIN
        INSERT INTO public.role_permissions (role, capability, is_enabled, farm_id)
        VALUES ('manager','view_costs',true,NULL);
        PERFORM tests.assert('M16: UNIQUE NULLS NOT DISTINCT يمنع تكراراً عاماً ثانياً', false, '');
    EXCEPTION WHEN unique_violation THEN
        PERFORM tests.assert('M16: UNIQUE NULLS NOT DISTINCT يمنع تكراراً عاماً ثانياً', true, '');
    END;

    PERFORM tests.assert('M16: without_auto=لا شيء — لا مفاتيح CASCADE',
        NOT EXISTS (SELECT 1 FROM pg_constraint
                     WHERE conrelid IN ('role_permissions'::regclass,'user_permissions'::regclass)
                       AND contype='f' AND confdeltype='c'), '');
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_role_permissions: كل الفحوص PASS — الرفض افتراضياً، العام للمدير، التفصيلي يغلب';
END; $final$;

ROLLBACK;