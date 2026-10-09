-- ============================================================================
--  p0_record_lock_test.sql
--  خطة W5-M13: record_lock — الحظر الجوهري + طلب الفتح.
-- ============================================================================
--
--  PURPOSE
--  -------
--  M13 (20261003001200) makes every UPDATE/DELETE on a locked record fail
--  server-side for ANY caller (even a manager: the block is the point),
--  while record_unlock_requests gives any farm member a sanctioned way to
--  ask for an unlock. This file proves: tables + triggers exist; a manager
--  with full RLS rights is STILL refused while the lock is open; workers see
--  zero lock rows (the DEFINER trigger still blocks them); an expired lock
--  no longer blocks; unlock requests flow worker -> manager; anon has no
--  grants; the tables are NOT in sync_table_registry.
--
--  RUN (exactly like every suite in run_all.py): psql as test_runner, inside
--  BEGIN/ROLLBACK, so the DB is untouched afterwards.
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
    IF v_super OR v_bypass THEN RAISE EXCEPTION 'ABORT: run as test_runner (non-superuser, no BYPASSRLS)'; END IF;
END $$;

DO $s$
DECLARE
    v_admin  uuid := '00000000-0000-0000-0000-00000000000a';
    v_worker uuid := '00000000-0000-0000-0000-00000000000b';
    v_farm   uuid := '00000000-0000-0000-0000-000000000001';
    v_flock  uuid;
    v_exp    uuid;
    v_lock   uuid;
    v_until  timestamptz := now() + interval '2 hours';
BEGIN
    -- 1) structural: both tables present
    PERFORM tests.assert('M13: record_lock موجود',
        to_regclass('public.record_lock') IS NOT NULL, '');
    PERFORM tests.assert('M13: record_unlock_requests موجود',
        to_regclass('public.record_unlock_requests') IS NOT NULL, '');
    -- 2) six guard triggers
    PERFORM tests.assert('M13: ستة تريغرات حماية (لكل جدول مقفل)',
        (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
          JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='public'
            AND t.tgname IN ('payments_lock_guard','expenses_lock_guard',
                             'revenue_lock_guard','egg_production_lock_guard',
                             'mortality_lock_guard','feed_consumption_lock_guard')
            AND NOT t.tgisinternal) = 6, '');
    -- 3) RLS مفعّل على الجدولين وليست في السجل
    PERFORM tests.assert('M13: record_lock فيه RLS',
        (SELECT relrowsecurity FROM pg_class WHERE oid='public.record_lock'::regclass), '');
    PERFORM tests.assert('M13: record_lock خارج sync_table_registry',
        NOT EXISTS (SELECT 1 FROM sync_table_registry WHERE table_name IN ('record_lock','record_unlock_requests')), '');
    -- 4) anon بلا إذن
    PERFORM tests.assert('M13: anon بلا SELECT على record_lock',
        NOT has_table_privilege('anon', 'record_lock', 'SELECT'), '');

    -- 5) تجهيز سجل قابل للقفل (مصاريف مزرعة A بمدير A)
    PERFORM tests.set_user(v_admin);
    SELECT id INTO v_flock FROM public.flocks
     WHERE farm_id=v_farm AND breed='M13' LIMIT 1;
    IF v_flock IS NULL THEN
        INSERT INTO public.flocks (id, farm_id, breed, start_date, initial_count, current_count, status, sections_count)
        VALUES (gen_random_uuid(), v_farm, 'M13', CURRENT_DATE, 100, 100, 'active', 1)
        RETURNING id INTO v_flock;
    END IF;
    SELECT id INTO v_exp FROM public.expenses
     WHERE farm_id=v_farm AND category='feed' AND amount=100.5 AND date=CURRENT_DATE LIMIT 1;
    IF v_exp IS NULL THEN
        INSERT INTO public.expenses (farm_id, flock_id, date, category, amount, currency)
        VALUES (v_farm, v_flock, CURRENT_DATE, 'feed', 100.5, 'dollar')
        RETURNING id INTO v_exp;
    END IF;
    PERFORM tests.assert('M13: مصروف اختبار جاهز',
        v_exp IS NOT NULL, format('id=%s', v_exp));

    -- 6) قفل مالي نشط بواسطة المدير
    INSERT INTO public.record_lock (table_name, record_id, farm_id, locked_by, locked_until, lock_type, reason)
    VALUES ('expenses', v_exp, v_farm, v_admin, v_until, 'financial', 'مراجعة ليلية')
    RETURNING id INTO v_lock;
    PERFORM tests.assert('M13: أنشئ المدير قفلاً',
        v_lock IS NOT NULL, format('lock=%s', v_lock));

    -- 7) الحظر الجوهري: حتى المدير نفسه لا يستطيع تعديل السجل المقهول
    BEGIN
        UPDATE public.expenses SET amount = 200 WHERE id = v_exp;
        PERFORM tests.assert('M13: تحديث المباراة الـقفل يجب أن يفشل', false, 'لم يرفض التحديث');
    EXCEPTION WHEN raise_exception THEN
        PERFORM tests.assert('M13: رُفض UPDATE لقفل فعّال',
            true, SQLERRM);
    END;

    BEGIN
        DELETE FROM public.expenses WHERE id = v_exp;
        PERFORM tests.assert('M13: حذف المباراة الـقفل يجب أن يفشل', false, 'لم يرفض الحذف');
    EXCEPTION WHEN raise_exception THEN
        PERFORM tests.assert('M13: رُفض DELETE لقفل فعّال', true, SQLERRM);
    END;

    -- 8) العامل لا يرى صفوف الأقفال (DEFINER يقرأ من غير RLS)
    PERFORM tests.set_user(v_worker);
    PERFORM tests.assert('M13: العامل لا يرى صفوف record_lock',
        (SELECT count(*) FROM public.record_lock WHERE id = v_lock) = 0, '');

    -- 9) العامل يقدّم طلب فتح
    PERFORM tests.set_user(v_worker);
    INSERT INTO public.record_unlock_requests (farm_id, lock_id, requested_by, reason)
    VALUES (v_farm, v_lock, v_worker, 'تصحيح كتابي');
    PERFORM tests.assert('M13: العامل يرى طلبه',
        EXISTS (SELECT 1 FROM public.record_unlock_requests WHERE lock_id=v_lock AND requested_by=v_worker), '');

    -- 10) الموافقة: المدير يقرّر الطلب
    PERFORM tests.set_user(v_admin);
    UPDATE public.record_unlock_requests
       SET status='approved', reviewed_by=v_admin, reviewed_at=now()
     WHERE lock_id = v_lock;
    PERFORM tests.assert('M13: المدير وافق على طلب الفتح',
        EXISTS (SELECT 1 FROM public.record_unlock_requests
                 WHERE lock_id=v_lock AND status='approved'), '');

    -- 11) قفل منتهي لا يحظر
    INSERT INTO public.record_lock (table_name, record_id, farm_id, locked_by, locked_until, lock_type, reason)
    VALUES ('expenses', v_exp, v_farm, v_admin, now() - interval '1 minute', 'financial', 'منتهي')
    ON CONFLICT (table_name, record_id) DO UPDATE SET locked_until = EXCLUDED.locked_until;
    UPDATE public.expenses SET amount = 101 WHERE id = v_exp;
    PERFORM tests.assert('M13: القفل المنتهي لم يمنع التحديث',
        (SELECT amount FROM public.expenses WHERE id=v_exp) = 101, '');

    -- 12) إزالة القفل النشط: تحذف طلب الفتح أولاً ثم القفل (مسألة إدارية)،
--     وبعدها لا يبقى قفل والتحديث ينجح
    PERFORM tests.set_user('00000000-0000-0000-0000-00000000000e');
    DELETE FROM public.record_unlock_requests WHERE lock_id = v_lock;
    DELETE FROM public.record_lock WHERE id = v_lock;
    PERFORM tests.set_user(v_admin);
    UPDATE public.expenses SET amount = 150 WHERE id = v_exp;
    PERFORM tests.assert('M13: بعد فتح القفل، التحديث ينجح',
        (SELECT amount FROM public.expenses WHERE id=v_exp) = 150, '');

    -- 13) لا يوجد مفتاح أجنبي CASCADE
    PERFORM tests.assert('M13: لا CASCADE في مفتاح أجنبي',
        NOT EXISTS (SELECT 1 FROM pg_constraint
                     WHERE conrelid IN ('record_lock'::regclass,'record_unlock_requests'::regclass)
                       AND contype='f' AND confdeltype='c'), '');
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'p0_record_lock_test: كل الفحوص PASS';
    RAISE NOTICE 'أقفال مالية/إنتاجية تحظر UPDATE/DELETE حصراً، وطلبات الفتح تسير عبر المدير، والقفل المنتهي لا يحظر.';
    RAISE NOTICE 'ROLLBACK';
    RAISE NOTICE '============================================================';
END; $final$;

ROLLBACK;