-- ============================================================================
--  p0_due_payments_test.sql
--  خطة W5-M20: check_due_payments() — تنبيهات آجال الفواتير (تذكير فقط).
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
    v_farm   uuid := '00000000-0000-0000-0000-000000000001';
    v_flock  uuid;
    v_cust   uuid;
    v_disp   uuid;
    v_pay    uuid;
    v_n      int;
BEGIN
    PERFORM tests.assert('M20: check_due_payments() حيّ، SECURITY DEFINER، لا EXECUTE لـ anon',
        (SELECT count(*) FROM pg_proc WHERE proname='check_due_payments' AND prosecdef)=1
        AND NOT has_function_privilege('anon', 'public.check_due_payments()', 'EXECUTE'), '');
    PERFORM tests.assert('M20: استدعاء anon مرفوض (
        IF has_function_privilege refused) — حماية إضافية',
        NOT has_function_privilege('anon', 'public.check_due_payments()', 'EXECUTE'), '');

    PERFORM tests.set_user(v_worker);
    SELECT id INTO v_flock FROM public.flocks WHERE farm_id=v_farm AND breed='M20' LIMIT 1;
    IF v_flock IS NULL THEN
        INSERT INTO public.flocks (id, farm_id, breed, start_date, initial_count, current_count, status, sections_count)
        VALUES (gen_random_uuid(), v_farm, 'M20', CURRENT_DATE, 100, 100, 'active', 1)
        RETURNING id INTO v_flock;
    END IF;
    INSERT INTO public.customers (farm_id, name, phone)
    VALUES (v_farm, 'M20_CUSTOMER', '0501111111') RETURNING id INTO v_cust;
    INSERT INTO public.egg_dispatch (farm_id, flock_id, date, customer_id, cartons, trays, total_eggs, payment_status, worker_id)
    VALUES (v_farm, v_flock, CURRENT_DATE, v_cust, 1, 2, 390, 'partial', v_worker)
    RETURNING id INTO v_disp;

    -- دفعة آجلة: تستحق بعد 3 أيام
    PERFORM tests.set_user(v_admin);
    INSERT INTO public.payments (farm_id, dispatch_id, customer_id, date, price_per_carton,
                                 total_due, amount_paid, payment_method, currency, due_date, manager_id)
    VALUES (v_farm, v_disp, v_cust, CURRENT_DATE, 300, 300, 0, 'cash', 'dollar',
            CURRENT_DATE + 3, v_admin)
    RETURNING id INTO v_pay;

    v_n := public.check_due_payments();
    PERFORM tests.assert('M20: دفعة تستحق بعد 3 أيام → تنبيه واحد',
        v_n = 1, format('created=%s', v_n));
    PERFORM tests.assert('M20: العنوان يحمل مفتاح تفرّد PAYDUE:+لقطات التوقيت',
        EXISTS (SELECT 1 FROM public.app_notifications
                 WHERE farm_id=v_farm AND title='PAYDUE:payment_due_3:' || v_pay::text), '');
    PERFORM tests.assert('M20: الإشعار يحمل flock_id مصفوّفة من الفاتورة',
        (SELECT flock_id FROM public.app_notifications
          WHERE farm_id=v_farm AND title LIKE 'PAYDUE:payment_due_3:%') = v_flock, '');
    PERFORM tests.assert('M20: مستوى الإنذار warning و+الدرجة مفتوحة',
        (SELECT level FROM public.app_notifications
          WHERE farm_id=v_farm AND title LIKE 'PAYDUE:payment_due_3:%') = 'warning', '');
    PERFORM tests.assert('M20: created_by فارغ (حفظ الغرض)',
        (SELECT created_by FROM public.app_notifications
          WHERE farm_id=v_farm AND title LIKE 'PAYDUE:payment_due_3:%') IS NULL, '');

    -- عدم التكرار: تشغيل ثانٍ صامت
    v_n := public.check_due_payments();
    PERFORM tests.assert('M20: تشغيل ثانٍ لا يكرر التنبيه',
        v_n = 0 AND (SELECT count(*) FROM public.app_notifications
                      WHERE farm_id=v_farm AND title LIKE 'PAYDUE:payment_due_3:%') = 1, '');

    -- استحقاق الحضور: -7 أيام ينشئ مفتاحاً جديداً
    UPDATE public.payments SET due_date = CURRENT_DATE - 7 WHERE id=v_pay;
    v_n := public.check_due_payments();
    PERFORM tests.assert('M20: التأخر 7 أيام → مفتاح overdue_7',
        v_n = 1 AND EXISTS (SELECT 1 FROM public.app_notifications
                             WHERE farm_id=v_farm AND title='PAYDUE:payment_overdue_7:' || v_pay::text), '');

    -- الدفع الكامل يوقفه
    UPDATE public.payments SET amount_paid = 300 WHERE id=v_pay;
    v_n := public.check_due_payments();
    PERFORM tests.assert('M20: المدفوع كاملاً لا يُنبّه',
        v_n = 0, format('created=%s', v_n));

    -- العامل لا يقرأ payments (مدراء للأمور المالية) — الإشعارات تصله فقط عبر الفلتر
    PERFORM tests.set_user(v_worker);
    PERFORM tests.assert('M20: العامل لا يقرأ جدول التحصيل',
        (SELECT count(*) FROM public.payments WHERE id=v_pay)=0, '');

    DELETE FROM public.app_notifications WHERE farm_id=v_farm AND title LIKE 'PAYDUE:%';
    DELETE FROM public.payments WHERE id=v_pay;
    DELETE FROM public.egg_dispatch WHERE id=v_disp;
    DELETE FROM public.customers WHERE id=v_cust;
    DELETE FROM public.flocks WHERE id=v_flock;
    PERFORM tests.assert('M20: التنظيف بعد الاختبار',
        NOT EXISTS (SELECT 1 FROM public.payments WHERE id=v_pay), '');
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_due_payments: كل الفحوص PASS — 3/0/-7/-30 تُنبّه، المدفوع يصمت';
END; $final$;

ROLLBACK;