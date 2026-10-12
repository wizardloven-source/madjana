-- ============================================================================
--  p0_partner_audit_test.sql
--  خطة W6-M23: partner_audit — سجل تدقيق القراءة فقط.
--  يعمل كـtest_runner (بدون BYPASSRLS) داخل BEGIN ... ROLLBACK.
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

DO $guard$
DECLARE v_super boolean; v_bypass boolean;
BEGIN
    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass FROM pg_roles WHERE rolname = current_user;
    IF v_super OR v_bypass THEN RAISE EXCEPTION 'ABORT: run as test_runner'; END IF;
END $guard$;

DO $s$
DECLARE
    v_sys    uuid := '00000000-0000-0000-0000-00000000000e';
    v_admin  uuid := '00000000-0000-0000-0000-00000000000a';
    v_worker uuid := '00000000-0000-0000-0000-00000000000b';
    v_adminB uuid := '00000000-0000-0000-0000-00000000000c';
    v_farmA  uuid := '00000000-0000-0000-0000-000000000001';
    v_farmB  uuid := '00000000-0000-0000-0000-000000000002';

    v_pa uuid := '44444444-0000-0000-0000-0000000000a1';
    v_a1 uuid := '55555555-0000-0000-0000-0000000000a1';
    v_a2 uuid := '55555555-0000-0000-0000-0000000000b1';

    v_n int;
BEGIN
    -- ── A) البنية ────────────────────────────────────────────────────────────
    PERFORM tests.assert('M23-audit: الجدول موجود',
        to_regclass('public.partner_audit') IS NOT NULL, '');

    PERFORM tests.assert('M23-audit: RLS مفعّل',
        (SELECT relrowsecurity FROM pg_class WHERE oid='public.partner_audit'::regclass), '');

    PERFORM tests.assert('M23-audit: سياسيتان فقط (admin_all + manager_read)',
        (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='partner_audit') = 2, '');

    PERFORM tests.assert('M23-audit: لا سياسة كتابة إطلاقاً',
        NOT EXISTS (SELECT 1 FROM pg_policies
                     WHERE schemaname='public' AND tablename='partner_audit' AND cmd <> 'SELECT'), '');

    PERFORM tests.assert('M23-audit: 4 فهارس',
        (SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND tablename='partner_audit') >= 4, '');

    PERFORM tests.assert('M23-audit: CHECK لقائمة الإجراءات',
        EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid='public.partner_audit'::regclass AND contype='c'), '');

    PERFORM tests.assert('M23-audit: FK farm_id RESTRICT / partner_id SET NULL',
        EXISTS (SELECT 1 FROM pg_constraint WHERE conname='partner_audit_farm_id_fkey' AND confdeltype='r')
        AND EXISTS (SELECT 1 FROM pg_constraint WHERE conname='partner_audit_partner_id_fkey' AND confdeltype='n'), '');

    PERFORM tests.assert('M23-audit: لا CASCADE',
        NOT EXISTS (SELECT 1 FROM pg_constraint
                     WHERE conrelid='public.partner_audit'::regclass AND confdeltype='c'), '');

    PERFORM tests.assert('M23-audit: anon بلا وصول',
        NOT has_table_privilege('anon','public.partner_audit','SELECT'), '');

    PERFORM tests.assert('M23-audit: authenticated للقراءة فقط',
        has_table_privilege('authenticated','public.partner_audit','SELECT')
        AND NOT has_table_privilege('authenticated','public.partner_audit','INSERT')
        AND NOT has_table_privilege('authenticated','public.partner_audit','UPDATE')
        AND NOT has_table_privilege('authenticated','public.partner_audit','DELETE'), '');

    PERFORM tests.assert('M23-audit: لا وصول PUBLIC (grantee 0)',
        NOT EXISTS (
            SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
            CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
            WHERE n.nspname='public' AND c.relname='partner_audit' AND a.grantee=0), '');

    PERFORM tests.assert('M23-audit: الكاتب record_partner_audit DEFINER، أنون محجوب، authenticated مصرّح',
        (SELECT prosecdef FROM pg_proc WHERE proname='record_partner_audit') IS TRUE
        AND NOT has_function_privilege('anon',
              'public.record_partner_audit(uuid,text,uuid,uuid,jsonb,jsonb,text,text,text)','EXECUTE')
        AND has_function_privilege('authenticated',
              'public.record_partner_audit(uuid,text,uuid,uuid,jsonb,jsonb,text,text,text)','EXECUTE'), '');

    -- ── B) الكتابة من الخادم (system_admin) ─────────────────────────────────
    PERFORM tests.set_user(v_sys);
    INSERT INTO public.partners (id, name, share_model, percentage)
        VALUES (v_pa, 'Audit Partner', 'percentage', 40);

    PERFORM public.record_partner_audit(v_farmA, 'added', v_sys, v_pa,
                                        '{}'::jsonb, jsonb_build_object('share', '40'));
    PERFORM tests.assert('M23-audit: إدخال سطر تدقيق لمزرعة A', true, '');

    PERFORM public.record_partner_audit(v_farmB, 'distribution_approved', v_sys, NULL,
                                        NULL, NULL, NULL, 'corr-1', '127.0.0.1');
    PERFORM tests.assert('M23-audit: partner_id يقبل NULL وcorrelation_id/ip يُخزّنان', true, '');

    -- ── C) العزل: مدير كل مزرعة يرى مزرعته فقط ─────────────────────────────
    PERFORM tests.set_user(v_admin);
    SELECT count(*) INTO v_n FROM public.partner_audit;
    PERFORM tests.assert('M23-audit: مدير A يرى سجل A فقط', v_n = 1, format('n=%s', v_n));

    PERFORM tests.set_user(v_adminB);
    SELECT count(*) INTO v_n FROM public.partner_audit;
    PERFORM tests.assert('M23-audit: مدير B يرى سجل B فقط', v_n = 1, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partner_audit WHERE farm_id = v_farmA;
    PERFORM tests.assert('M23-audit: مدير B لا يرى سجل A', v_n = 0, format('n=%s', v_n));

    PERFORM tests.set_user(v_worker);
    SELECT count(*) INTO v_n FROM public.partner_audit;
    PERFORM tests.assert('M23-audit: العامل لا يرى شيئاً', v_n = 0, format('n=%s', v_n));

    -- ── D) الإجراء المدقّق مقيّد ─────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);
    BEGIN
        PERFORM public.record_partner_audit(v_farmA, 'bogus_action', v_sys);
        PERFORM tests.assert('M23-audit: إجراء غير معروف مرفوض', false, 'مرّ الإجراء');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M23-audit: إجراء غير معروف مرفوض', true, SQLERRM);
    END;

    BEGIN
        PERFORM public.record_partner_audit(v_farmA, 'withdrawal_paid', NULL);
        PERFORM tests.assert('M23-audit: changed_by إلزامي', false, 'مرّ NULL');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M23-audit: changed_by إلزامي', true, SQLERRM);
    END;

    PERFORM public.record_partner_audit(v_farmA, 'withdrawal_paid', v_sys);
    PERFORM tests.assert('M23-audit: إجراء صحيح من الخادم مسموح', true, '');

    -- ── E) المدير لا يكتب السجل ─────────────────────────────────────────────
    PERFORM tests.set_user(v_admin);
    BEGIN
        PERFORM public.record_partner_audit(v_farmA, 'added', v_admin);
        PERFORM tests.assert('M23-audit: المدير لا يستطيع الكتابة', false, 'نجحت الكتابة');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M23-audit: المدير لا يستطيع الكتابة', true, SQLERRM);
    END;

    BEGIN
        INSERT INTO public.partner_audit (farm_id, action, changed_by)
            VALUES (v_farmA, 'added', v_admin);
        PERFORM tests.assert('M23-audit: الإدراج المباشر في الجدول ممنوع', false, 'نجح الإدراج');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M23-audit: الإدراج المباشر في الجدول ممنوع', true, SQLERRM);
    END;

    -- السجل غير قابل للتعديل: لا صلاحية UPDATE إطلاقاً
    PERFORM tests.set_user(v_admin);
    BEGIN
        UPDATE public.partner_audit SET notes='tamper' WHERE farm_id=v_farmA;
        PERFORM tests.assert('M23-audit: السجل غير قابل للتعديل', false, 'نجح التعديل');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M23-audit: السجل غير قابل للتعديل', true, SQLERRM);
    END;

    RAISE NOTICE 'p0_partner_audit: انتهى';
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_partner_audit: كل الفحوص PASS — قراءة فقط، معزول، مُدقّق';
END; $final$;

ROLLBACK;
