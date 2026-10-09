-- ============================================================================
--  p0_farm_id_audit_test.sql
--  خطة W5-M18: farm_id_audit — سجل نقل السجلات بين المزارع.
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
    v_admin  uuid := '00000000-0000-0000-0000-00000000000a';
    v_worker uuid := '00000000-0000-0000-0000-00000000000b';
    v_adminb uuid := '00000000-0000-0000-0000-00000000000c';
    v_sys    uuid := '00000000-0000-0000-0000-00000000000e';
    v_farm   uuid := '00000000-0000-0000-0000-000000000001';
    v_farmb  uuid := '00000000-0000-0000-0000-000000000002';
    v_flock  uuid;
    v_exp    uuid;
    v_cust   uuid;
BEGIN
    PERFORM tests.assert('M18: الجدول موجود والكاتب DEFINER',
        to_regclass('public.farm_id_audit') IS NOT NULL
        AND (SELECT count(*) FROM pg_proc WHERE proname='trg_farm_id_audit' AND prosecdef)=1, '');
    PERFORM tests.assert('M18: 13 تريغتراً على الجداول ذات farm_id',
        (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
          JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='public' AND t.tgname LIKE '%_farm_id_audit' AND NOT t.tgisinternal)=13, '');

    PERFORM tests.set_user(v_admin);
    SELECT id INTO v_flock FROM public.flocks WHERE farm_id=v_farm AND breed='M18' LIMIT 1;
    IF v_flock IS NULL THEN
        INSERT INTO public.flocks (id, farm_id, breed, start_date, initial_count, current_count, status, sections_count)
        VALUES (gen_random_uuid(), v_farm, 'M18', CURRENT_DATE, 100, 100, 'active', 1)
        RETURNING id INTO v_flock;
    END IF;
    INSERT INTO public.expenses (farm_id, flock_id, date, category, amount, currency)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'water', 50, 'dollar')
    RETURNING id INTO v_exp;

    -- تحديث في نفس المزرعة: لا سجل
    UPDATE public.expenses SET amount = 51 WHERE id=v_exp;
    PERFORM tests.assert('M18: تحديث بلا تغيير مزرعة لا يكتب سجلاً',
        NOT EXISTS (SELECT 1 FROM public.farm_id_audit WHERE record_id=v_exp), '');

    -- النقل إلى مزرعة B: مسارٌ خالٍ من Validate_flock_farm (لا ربط بالفلوك)
    INSERT INTO public.customers (farm_id, name, phone)
    VALUES (v_farm, 'M18_MOVE_ME', '0502222222') RETURNING id INTO v_cust;
    PERFORM tests.assert('M18: عميلُ الاختبار في المزرعة A',
        (SELECT farm_id FROM public.customers WHERE id=v_cust) = v_farm, '');

    PERFORM tests.set_user(v_sys);
    UPDATE public.customers SET farm_id=v_farmb WHERE id=v_cust;
    PERFORM tests.assert('M18: النقل old→new سُجّل',
        EXISTS (SELECT 1 FROM public.farm_id_audit
                 WHERE record_id=v_cust AND table_name='customers'
                   AND old_farm_id=v_farm AND new_farm_id=v_farmb), '');
    PERFORM tests.assert('M18: changed_by = مُنفّذ النقل',
        (SELECT changed_by FROM public.farm_id_audit WHERE record_id=v_cust) = v_sys, '');

    -- القراءة لمدارة المزرعتين فقط
    PERFORM tests.set_user(v_worker);
    PERFORM tests.assert('M18: العامل لا يقرأ السجل',
        (SELECT count(*) FROM public.farm_id_audit WHERE record_id=v_cust)=0, '');
    PERFORM tests.set_user(v_admin);
    PERFORM tests.assert('M18: مدير المزرعة القديمة يقرأ',
        EXISTS (SELECT 1 FROM public.farm_id_audit WHERE record_id=v_cust), '');
    PERFORM tests.set_user(v_adminb);
    PERFORM tests.assert('M18: مدير المزرعة الجديدة يقرأ أيضاً',
        EXISTS (SELECT 1 FROM public.farm_id_audit WHERE record_id=v_cust), '');

    PERFORM tests.assert('M18: الجدول خارج المزامنة (سجل حوكمة)',
        NOT EXISTS (SELECT 1 FROM sync_table_registry WHERE table_name='farm_id_audit')
        AND (SELECT count(*) FROM sync_table_registry) >= 21
        AND coalesce((SELECT public.current_user_role()), '') = 'manager', '');

    -- حذف السجل والصفوف: يُسبق بـ ROLLBACK في نهاية المجموعة
    DELETE FROM public.customers WHERE id=v_cust;
    DELETE FROM public.expenses WHERE id=v_exp;
    DELETE FROM public.flocks WHERE id=v_flock;
    PERFORM tests.assert('M18: التنظيف بعد الاختبار',
        NOT EXISTS (SELECT 1 FROM public.customers WHERE id=v_cust)
        AND NOT EXISTS (SELECT 1 FROM public.expenses WHERE id=v_exp), '');
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_farm_id_audit: كل الفحوص PASS — نقلُ مزرعة يوثَّق، القراءة للمدارة';
END; $final$;

ROLLBACK;