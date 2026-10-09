-- ============================================================================
--  p0_invoice_audit_test.sql
--  خطة W5-M15: تتبع تعديل وحذف فواتير egg_dispatch في audit_log الموجود.
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
    v_rows   int;
BEGIN
    PERFORM tests.assert('M15: الكاتب trg_audit_invoice حي وDEFINER',
        (SELECT count(*) FROM pg_proc WHERE proname='trg_audit_invoice' AND prosecdef)=1, '');

    PERFORM tests.set_user(v_worker);
    SELECT id INTO v_flock FROM public.flocks WHERE farm_id=v_farm AND breed='M15' LIMIT 1;
    IF v_flock IS NULL THEN
        INSERT INTO public.flocks (id, farm_id, breed, start_date, initial_count, current_count, status, sections_count)
        VALUES (gen_random_uuid(), v_farm, 'M15', CURRENT_DATE, 100, 100, 'active', 1)
        RETURNING id INTO v_flock;
    END IF;
    INSERT INTO public.customers (farm_id, name, phone)
    VALUES (v_farm, 'M15_CUSTOMER', '0500000000')
    RETURNING id INTO v_cust;
    INSERT INTO public.egg_dispatch (farm_id, flock_id, date, customer_id, cartons, trays, total_eggs, payment_status, worker_id)
    VALUES (v_farm, v_flock, CURRENT_DATE, v_cust, 1, 2, 390, 'unpaid', v_worker)
    RETURNING id INTO v_disp;
    PERFORM tests.assert('M15: فاتورة شحن جاهزة', v_disp IS NOT NULL, format('disp=%s', v_disp));

    -- تعديل بفاتورة: UPDATE of cartons
    UPDATE public.egg_dispatch SET cartons = 2 WHERE id = v_disp;
    PERFORM tests.assert('M15: update(cartons) سُمح على طريق العامل',
        (SELECT cartons FROM public.egg_dispatch WHERE id=v_disp)=2, '');

    -- القراءة من audit_log تخص المدراء فقط
    PERFORM tests.set_user(v_worker);
    SELECT count(*) INTO v_rows FROM public.audit_log
     WHERE table_name='egg_dispatch' AND record_id=v_disp;
    PERFORM tests.assert('M15: العامل لا يقرأ سجلَّ التدقيق',
        v_rows = 0, format('rows=%s (bypass لـ RLS؟)', v_rows));

    PERFORM tests.set_user(v_admin);
    SELECT count(*) INTO v_rows FROM public.audit_log
     WHERE table_name='egg_dispatch' AND record_id=v_disp AND action='UPDATE';
    PERFORM tests.assert('M15: سجل UPDATE في audit_log بالحقول القديمة/الجديدة',
        v_rows = 1, format('rows=%s', v_rows));
    PERFORM tests.assert('M15: العملية مسجلة بمعرّف العامل',
        (SELECT user_id FROM public.audit_log
          WHERE table_name='egg_dispatch' AND record_id=v_disp AND action='UPDATE') = v_worker, '');
    PERFORM tests.assert('M15: old_values تحمل cartons=1',
        ((SELECT old_values::jsonb FROM public.audit_log
            WHERE table_name='egg_dispatch' AND record_id=v_disp AND action='UPDATE') ->> 'cartons') = '1', '');
    PERFORM tests.assert('M15: new_values تحمل cartons=2',
        ((SELECT new_values::jsonb FROM public.audit_log
            WHERE table_name='egg_dispatch' AND record_id=v_disp AND action='UPDATE') ->> 'cartons') = '2', '');

    -- حذف الفاتورة: سجل DELETE
    DELETE FROM public.egg_dispatch WHERE id=v_disp;
    PERFORM tests.assert('M15: سجل DELETE في audit_log',
        EXISTS (SELECT 1 FROM public.audit_log
                 WHERE table_name='egg_dispatch' AND record_id=v_disp AND action='DELETE'), '');

    -- نفس الـ farm_id وأسعار داخل الحدود لا تطلق أي ضجيج إضافي
    PERFORM tests.assert('M15: لا سجلات دخيلة بعد قائمتنا',
        NOT EXISTS (SELECT 1 FROM public.audit_log
                     WHERE table_name='egg_dispatch' AND record_id=v_disp
                       AND action NOT IN ('UPDATE','DELETE')), '');

    DELETE FROM public.customers WHERE id=v_cust;
    DELETE FROM public.flocks WHERE id=v_flock;
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_invoice_audit: كل الفحوص PASS — كل تعديل/حذف فاتورة يكتب audit_log';
END; $final$;

ROLLBACK;