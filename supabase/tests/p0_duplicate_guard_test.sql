-- ============================================================================
--  p0_duplicate_guard_test.sql
--  خطة W5-M19: duplicate_guard — بصمة التكرار + تجاوز المدير المعتمد.
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
    v_sys    uuid := '00000000-0000-0000-0000-00000000000e';
    v_farm   uuid := '00000000-0000-0000-0000-000000000001';
    v_flock  uuid;
    v_fp     text;
BEGIN
    PERFORM tests.assert('M19: الجدول والحارس موجودان',
        to_regclass('public.duplicate_guard') IS NOT NULL
        AND (SELECT count(*) FROM pg_proc WHERE proname='trg_duplicate_guard' AND prosecdef)=1
        AND (SELECT count(*) FROM pg_proc WHERE proname='dup_fingerprint')=1, '');
    PERFORM tests.assert('M19: ستة حوّارسات BEFORE INSERT',
        (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
          JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='public' AND t.tgname LIKE '%_duplicate_guard' AND NOT t.tgisinternal)=6, '');
    PERFORM tests.assert('M19: فهرس فريد جزئي (WHERE NOT blocked)',
        EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
                 JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND c.relname LIKE 'uq_duplicate_guard_%'
                   AND i.indpred IS NOT NULL), '');

    PERFORM tests.set_user(v_admin);
    SELECT id INTO v_flock FROM public.flocks WHERE farm_id=v_farm AND breed='M19' LIMIT 1;
    IF v_flock IS NULL THEN
        INSERT INTO public.flocks (id, farm_id, breed, start_date, initial_count, current_count, status, sections_count)
        VALUES (gen_random_uuid(), v_farm, 'M19', CURRENT_DATE, 100, 100, 'active', 1)
        RETURNING id INTO v_flock;
    END IF;

    -- الإدراج الأول: يُقبل + يُنشأ وَسْم؛ البصمة تُستعاد من الصف المخزّن
    -- (تطابق تمثيل numeric(16,8) مثل "100.50000000")
    INSERT INTO public.expenses (farm_id, flock_id, date, category, amount, currency)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'feed', 100.5, 'dollar');
    SELECT public.dup_fingerprint('expenses', to_jsonb(e)) INTO v_fp
      FROM public.expenses e
     WHERE e.farm_id=v_farm AND e.flock_id=v_flock AND e.category='feed'
       AND e.amount=100.5 AND e.date=CURRENT_DATE
     LIMIT 1;
    PERFORM tests.assert('M19: أول إدراج يُقبل والوَسْم (unblocked) يُخزَّن',
        EXISTS (SELECT 1 FROM public.duplicate_guard
                 WHERE farm_id=v_farm AND table_name='expenses'
                   AND fingerprint=v_fp AND NOT blocked), '');

    -- المكرر العيني: رفض
    BEGIN
        INSERT INTO public.expenses (farm_id, flock_id, date, category, amount, currency)
        VALUES (v_farm, v_flock, CURRENT_DATE, 'feed', 100.5, 'dollar');
        PERFORM tests.assert('M19: المكرر مرفوض', false, 'قُبل ثانية');
    EXCEPTION WHEN raise_exception THEN
        PERFORM tests.assert('M19: المكرر مرفوض', true, SQLERRM);
    END;

    -- مبلغ مختلف: مباح
    INSERT INTO public.expenses (farm_id, flock_id, date, category, amount, currency)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'feed', 99.5, 'dollar');
    PERFORM tests.assert('M19: بصمة مختلفة (مبلغ) مباحة',
        (SELECT count(*) FROM public.expenses WHERE farm_id=v_farm AND category='feed')=2, '');

    -- حارس آخر: egg_production (عامل)، القِسم يعرّف التكرار
    PERFORM tests.set_user(v_worker);
    INSERT INTO public.egg_production (farm_id, flock_id, date, cartons, trays, loose_eggs, total_eggs, section_no, worker_id)
    VALUES (v_farm, v_flock, CURRENT_DATE, 1, 0, 0, 30, 1, v_worker);
    BEGIN
        INSERT INTO public.egg_production (farm_id, flock_id, date, cartons, trays, loose_eggs, total_eggs, section_no, worker_id)
        VALUES (v_farm, v_flock, CURRENT_DATE, 1, 0, 0, 30, 1, v_worker);
        PERFORM tests.assert('M19: تكرار إنتاج القسم نفسه مرفوض', false, '');
    EXCEPTION WHEN raise_exception THEN
        PERFORM tests.assert('M19: تكرار إنتاج القسم نفسه مرفوض', true, SQLERRM);
    END;
    -- قسم مختلف: مباح
    INSERT INTO public.egg_production (farm_id, flock_id, date, cartons, trays, loose_eggs, total_eggs, section_no, worker_id)
    VALUES (v_farm, v_flock, CURRENT_DATE, 1, 0, 0, 30, 2, v_worker);
    PERFORM tests.assert('M19: قسم مختلف مباح',
        (SELECT count(*) FROM public.egg_production WHERE farm_id=v_farm AND flock_id=v_flock AND section_no IN (1,2))=2, '');

    -- المكرر المتَعمد: المدير يوقّع وسم التجاوز، ثم يُقبل تماماً
    PERFORM tests.set_user(v_sys);
    UPDATE public.duplicate_guard
       SET blocked=true, reason='مدفوع مرتين عن قصد (تعويض)'
     WHERE farm_id=v_farm AND table_name='expenses' AND fingerprint=v_fp;
    PERFORM tests.assert('M19: المدير الوسم كـ blocked (تجاوز معتمد)',
        EXISTS (SELECT 1 FROM public.duplicate_guard WHERE fingerprint=v_fp AND blocked), '');
    PERFORM tests.set_user(v_admin);
    INSERT INTO public.expenses (farm_id, flock_id, date, category, amount, currency)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'feed', 100.5, 'dollar');
    PERFORM tests.assert('M19: الإدراج بعد علامة التجاوز ينجح',
        (SELECT count(*) FROM public.expenses WHERE farm_id=v_farm AND category='feed')=3, '');

    -- الفهرس الجزئي: وَسْم unblocked ثانٍ لنفس البصمة مرفوض حتى يدوياً
    PERFORM tests.set_user(v_sys);
    BEGIN
        INSERT INTO public.duplicate_guard (id, farm_id, table_name, fingerprint, record_id, created_by)
        VALUES (gen_random_uuid(), v_farm, 'expenses', v_fp, '00000000-0000-0000-0000-00000000ff19', v_sys);
        PERFORM tests.assert('M19: لا وَسْمَين غير مقفولين لنفس البصمة', false, 'قُبل وسم ثانٍ');
    EXCEPTION WHEN unique_violation THEN
        PERFORM tests.assert('M19: لا وَسْمَين غير مقفولين لنفس البصمة', true, '');
    END;

    PERFORM tests.assert('M19: الجدول خارج المزامنة',
        NOT EXISTS (SELECT 1 FROM sync_table_registry WHERE table_name='duplicate_guard'), '');

    DELETE FROM public.duplicate_guard WHERE farm_id=v_farm;
    DELETE FROM public.egg_production WHERE farm_id=v_farm;
    DELETE FROM public.expenses WHERE farm_id=v_farm;
    DELETE FROM public.flocks WHERE id=v_flock;
    PERFORM tests.assert('M19: التنظيف بعد الاختبار',
        NOT EXISTS (SELECT 1 FROM public.duplicate_guard WHERE farm_id=v_farm), '');
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_duplicate_guard: كل الفحوص PASS — البصمة توقف العين، علامة المدير تفتح للمقصود';
END; $final$;

ROLLBACK;