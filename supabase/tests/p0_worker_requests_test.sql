-- ============================================================================
--  p0_worker_requests_test.sql
--  خطة W5-M14: change_requests — طلبات العامل المُزامنة برتبة 210.
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
    v_adminb uuid := '00000000-0000-0000-0000-00000000000c';
    v_farm   uuid := '00000000-0000-0000-0000-000000000001';
    v_farmb  uuid := '00000000-0000-0000-0000-000000000002';
    v_req    uuid;
    v_sort   int;
    v_sync   int;
BEGIN
    PERFORM tests.assert('M14: change_requests موجود',
        to_regclass('public.change_requests') IS NOT NULL, '');
    PERFORM tests.assert('M14: RLS مفعّل',
        (SELECT relrowsecurity FROM pg_class WHERE oid='public.change_requests'::regclass), '');
    -- بالسجل حاجب إحكام؛ القراءة تفتح للمدير/النظام — نقرؤها بعد تعيين المدير
    PERFORM tests.set_user(v_admin);
    SELECT sort_order INTO v_sort FROM sync_table_registry WHERE table_name='change_requests';
    PERFORM tests.assert('M14: رتبة المزامنة الأعلى = يُطبَّق متأخراً عن flocks',
        v_sort IS NOT NULL AND v_sort > (SELECT sort_order FROM sync_table_registry WHERE table_name='flocks'),
        format('sort_order=%s', v_sort));

    PERFORM tests.assert('M14: تريغرات المزامنة (insert/update/tombstone) للجدول',
        (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
          JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='public' AND c.relname='change_requests'
            AND t.tgname IN ('change_requests_sync_insert','change_requests_sync_update','change_requests_tombstone')
            AND NOT t.tgisinternal) = 3, '');

    -- العامل يقدّم طلباً عن نفسه
    PERFORM tests.set_user(v_worker);
    INSERT INTO public.change_requests (farm_id, requested_by, kind, payload)
    VALUES (v_farm, v_worker, 'expense',
            jsonb_build_object('type','expense','amount',300,'currency','lira'))
    RETURNING id INTO v_req;
    PERFORM tests.assert('M14: العامل أنشأ طلبه (requested_by=نفسه)',
        v_req IS NOT NULL, format('req=%s', v_req));

    -- لا يستطيع ادعاء أنه طُلب باسم المدير (قيود WITH CHECK)
    BEGIN
        INSERT INTO public.change_requests (farm_id, requested_by, kind, payload)
        VALUES (v_farm, v_admin, 'expense', '{}'::jsonb);
        PERFORM tests.assert('M14: رفض تزوير الطالب', false, 'قُبل طلب باسم المدير');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M14: رفض تزوير الطالب', true, SQLERRM);
    END;

    -- المزامنة: sync_changes حصل على صف INSERT
    SELECT count(*) INTO v_sync FROM public.sync_changes
     WHERE table_name='change_requests' AND record_id=v_req AND operation='INSERT';
    PERFORM tests.assert('M14: صف INSERT وصل إلى sync_changes',
        v_sync = 1, format('rows=%s', v_sync));

    -- العامل لا يغيّر الحالة (RLS UPDATE يفلتر الصف بصمت)، ولا يرى إلا مزرعته
    PERFORM tests.set_user(v_worker);
    UPDATE public.change_requests SET status='approved' WHERE id=v_req;
    PERFORM tests.assert('M14: العامل لا يوافق',
        (SELECT status FROM public.change_requests WHERE id=v_req) <> 'approved', '');
    PERFORM tests.assert('M14: العامل يقرأ طلبه فقط',
        (SELECT count(*) FROM public.change_requests WHERE id=v_req AND farm_id=v_farm) = 1, '');

    -- مدير المزرعة الأخرى لا يرى الطلب (RLS user_has_farm_access)
    PERFORM tests.set_user(v_adminb);
    PERFORM tests.assert('M14: مدير المزرعة الأخرى لا يرى الطلب',
        NOT EXISTS (SELECT 1 FROM public.change_requests WHERE id=v_req), '');

    -- المدير يقرأ ويوافق
    PERFORM tests.set_user(v_admin);
    PERFORM tests.assert('M14: المدير يرى طلب مزرعته',
        EXISTS (SELECT 1 FROM public.change_requests WHERE id=v_req AND farm_id=v_farm), '');
    UPDATE public.change_requests
       SET status='approved', decided_by=v_admin, decided_at=now(), decision_note='موافق'
     WHERE id=v_req;
    PERFORM tests.assert('M14: المدير وافق',
        EXISTS (SELECT 1 FROM public.change_requests WHERE id=v_req AND status='approved'), '');

    PERFORM tests.set_user(v_admin);
    DELETE FROM public.change_requests WHERE id=v_req;
    PERFORM tests.assert('M14: المدير يستطيع حذف الطلب',
        NOT EXISTS (SELECT 1 FROM public.change_requests WHERE id=v_req), '');

    PERFORM tests.assert('M14: لا CASCADE في المفاتيح',
        NOT EXISTS (SELECT 1 FROM pg_constraint
                     WHERE conrelid='change_requests'::regclass
                       AND contype='f' AND confdeltype='c'), '');
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_worker_requests: كل الفحوص PASS — طلبات عامل -> موافقة مدير -> مزامنة 210';
END; $final$;

ROLLBACK;