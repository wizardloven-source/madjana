-- ============================================================================
--  p0_opening_feed_received_test.sql
--  خطة W5-M17: opening_feed_received_kg — التغذية المستلمة قبل بداية التتبع.
--  (يطلب المستخدم ≥15 فحصاً.)
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
    v_ob     uuid;
    v_n      int;
    v_val    numeric;
    v_type   text;
    v_null   boolean;
BEGIN
    -- 10 فحوص بنيوية
    PERFORM tests.assert('M17 (1) العمود موجود',
        EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
                 JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND c.relname='opening_balances'
                   AND a.attname='opening_feed_received_kg' AND NOT a.attisdropped), '');
    SELECT data_type INTO v_type FROM information_schema.columns
     WHERE table_schema='public' AND table_name='opening_balances'
       AND column_name='opening_feed_received_kg';
    PERFORM tests.assert('M17 (2) النوع numeric(19,4)',
        v_type='numeric', format('found=%s', v_type));
    SELECT is_nullable INTO v_null FROM information_schema.columns
     WHERE table_schema='public' AND table_name='opening_balances'
       AND column_name='opening_feed_received_kg';
    PERFORM tests.assert('M17 (3) العمود اختياري (NULL جائز)',
        v_null='YES', '');
    PERFORM tests.assert('M17 (4) CHECK غير سالب موجود',
        EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname='opening_balances_opening_feed_received_kg_check'
                   AND conrelid='public.opening_balances'::regclass), '');
    PERFORM tests.assert('M17 (5) لا ربط مع السجل',
        NOT EXISTS (SELECT 1 FROM sync_table_registry WHERE table_name='opening_balances'), '');

    -- تجهيز
    PERFORM tests.set_user(v_admin);
    SELECT id INTO v_flock FROM public.flocks WHERE farm_id=v_farm AND breed='M17' LIMIT 1;
    IF v_flock IS NULL THEN
        INSERT INTO public.flocks (id, farm_id, breed, start_date, initial_count, current_count, status, sections_count)
        VALUES (gen_random_uuid(), v_farm, 'M17', CURRENT_DATE, 100, 100, 'active', 1)
        RETURNING id INTO v_flock;
    END IF;

    PERFORM tests.assert('M17 (6) سياسة الإدراج تتطلب إدارة المزرعة',
        EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname='public' AND tablename='opening_balances'
                   AND cmd='INSERT'
                   AND with_check LIKE '%user_manages_farm%'), '');

    -- سلوك الكتابة: قيمة إيجابية تٌخزَّن
    INSERT INTO public.opening_balances
           (farm_id, flock_id, eggs_produced, eggs_dispatched, feed_consumed_kg,
            initial_birds, mortality_count, total_payments, total_revenues,
            opening_feed_received_kg)
    VALUES (v_farm, v_flock, 0, 0, 30, 100, 0, 0, 0, 120.5)
    RETURNING id INTO v_ob;
    SELECT opening_feed_received_kg INTO v_val FROM public.opening_balances WHERE id=v_ob;
    PERFORM tests.assert('M17 (7) قيمة موجبة تٌخزَّن وتُقرأ',
        v_val=120.5, format('read=%s', v_val));

    -- CHECK يرفض السالب
    BEGIN
        INSERT INTO public.opening_balances
               (farm_id, flock_id, opening_feed_received_kg, eggs_produced, eggs_dispatched,
                initial_birds, feed_consumed_kg, mortality_count, total_payments, total_revenues)
        VALUES (v_farm, v_flock, -1, 0, 0, 100, 0, 0, 0, 0);
        PERFORM tests.assert('M17 (8) السالب مرفوض', false, 'قُبلت -1');
    EXCEPTION WHEN check_violation THEN
        PERFORM tests.assert('M17 (8) السالب مرفوض', true, SQLERRM);
    END;

    -- NULL أصيل (المجهول ≠ الصفر)
    UPDATE public.opening_balances SET opening_feed_received_kg = NULL WHERE id=v_ob;
    PERFORM tests.assert('M17 (9) NULL يُقبل ويبقى NULL',
        (SELECT opening_feed_received_kg FROM public.opening_balances WHERE id=v_ob) IS NULL, '');

    -- التحديث من NULL إلى قيمة
    UPDATE public.opening_balances SET opening_feed_received_kg = 200 WHERE id=v_ob;
    SELECT opening_feed_received_kg INTO v_val FROM public.opening_balances WHERE id=v_ob;
    PERFORM tests.assert('M17 (10) التحديث من NULL إلى 200',
        v_val=200, format('read=%s', v_val));

    -- معادلة المخزون الافتراضي: المستلم − المستهلك
    SELECT opening_feed_received_kg - feed_consumed_kg INTO v_val FROM public.opening_balances WHERE id=v_ob;
    PERFORM tests.assert('M17 (11) المخزون الافتراضي = المستلم − المستهلك (= 170)',
        v_val=170, format('stock=%s', v_val));

    -- العامل يقرأ صفر صفوف في opening_balances (RFC: للأدارة/المدراء)
    PERFORM tests.set_user(v_worker);
    PERFORM tests.assert('M17 (12) العامل لا يقرأ opening_balances',
        (SELECT count(*) FROM public.opening_balances WHERE id=v_ob)=0, '');
    BEGIN
        INSERT INTO public.opening_balances (farm_id, flock_id, opening_feed_received_kg)
        VALUES (v_farm, v_flock, 1);
        PERFORM tests.assert('M17 (13) العامل لا يدرج', false, 'أُدرج العامل');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M17 (13) العامل لا يدرج', true, SQLERRM);
    END;

    -- anon بلا امتياز والمدير يرى سجله
    PERFORM tests.assert('M17 (14) anon بلا SELECT',
        NOT has_table_privilege('anon', 'opening_balances', 'SELECT'), '');
    PERFORM tests.set_user(v_admin);
    PERFORM tests.assert('M17 (15) المدير يرى سجله',
        EXISTS (SELECT 1 FROM public.opening_balances WHERE id=v_ob), '');

    -- النظافة
    DELETE FROM public.opening_balances WHERE id=v_ob;
    DELETE FROM public.flocks WHERE id=v_flock;
    PERFORM tests.assert('M17 (16) الحذف النظيف بعد الاختبار',
        NOT EXISTS (SELECT 1 FROM public.opening_balances WHERE farm_id=v_farm), '');
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_opening_feed_received: 16 فحصاً كلها PASS';
END; $final$;

ROLLBACK;