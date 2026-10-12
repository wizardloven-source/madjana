-- ============================================================================
--  p0_partner_withdrawals_test.sql
--  خطة W6-M23: partner_withdrawals
--  الاختبار يعمل كـtest_runner (بدون BYPASSRLS) عبر run_all.py، لذا كل فحص
--  RLS حقيقي. كل شيء داخل BEGIN ... ROLLBACK ولا يمسّ بيانات دائمة.
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
    v_sys     uuid := '00000000-0000-0000-0000-00000000000e';
    v_admin   uuid := '00000000-0000-0000-0000-00000000000a';
    v_worker  uuid := '00000000-0000-0000-0000-00000000000b';
    v_adminB  uuid := '00000000-0000-0000-0000-00000000000c';
    v_farmA   uuid := '00000000-0000-0000-0000-000000000001';
    v_farmB   uuid := '00000000-0000-0000-0000-000000000002';

    v_pa uuid := '11111111-0000-0000-0000-0000000000a1';
    v_pb uuid := '11111111-0000-0000-0000-0000000000b1';
    v_pc uuid := '11111111-0000-0000-0000-0000000000c1';

    v_da uuid := '22222222-0000-0000-0000-0000000000a1';
    v_db uuid := '22222222-0000-0000-0000-0000000000b1';

    v_w1 uuid := '33333333-0000-0000-0000-0000000000a1';
    v_w2 uuid := '33333333-0000-0000-0000-0000000000a2';
    v_w3 uuid := '33333333-0000-0000-0000-0000000000a3';
    v_w4 uuid := '33333333-0000-0000-0000-0000000000b1';
    v_w5 uuid := '33333333-0000-0000-0000-0000000000a5';
    v_w6 uuid := '33333333-0000-0000-0000-0000000000a6';
    v_wa uuid := '33333333-0000-0000-0000-0000000000c1';

    v_n int;
BEGIN
    -- ── A) البنية ────────────────────────────────────────────────────────────
    PERFORM tests.assert('M23: الجدولان موجودان',
        to_regclass('public.partner_withdrawals') IS NOT NULL
        AND to_regclass('public.partner_audit') IS NOT NULL, '');

    PERFORM tests.assert('M23: RLS مفعّل على الجدولين',
        (SELECT bool_and(relrowsecurity) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='public' AND c.relname IN ('partner_withdrawals','partner_audit')), '');

    PERFORM tests.assert('M23: 5 سياسات على partner_withdrawals',
        (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='partner_withdrawals') = 5, '');

    PERFORM tests.assert('M23: 2 سياسات على partner_audit',
        (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='partner_audit') = 2, '');

    PERFORM tests.assert('M23: partner_audit للقراءة فقط (لا سياسة كتابة)',
        NOT EXISTS (SELECT 1 FROM pg_policies
                     WHERE schemaname='public' AND tablename='partner_audit' AND cmd <> 'SELECT'), '');

    PERFORM tests.assert('M23: CHECK حالة/حقل موجودان',
        EXISTS (SELECT 1 FROM pg_constraint WHERE conname='partner_withdrawals_rejected_reason')
        AND EXISTS (SELECT 1 FROM pg_constraint WHERE conname='partner_withdrawals_paid_at'), '');

    PERFORM tests.assert('M23: 5 triggers مثبتة',
        (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname IN (
            'trg_partner_withdrawals_updated_at','trg_partner_withdrawals_validate',
            'trg_partner_withdrawals_guard','trg_partner_withdrawals_sync',
            'trg_partner_withdrawals_tombstone')) = 5, '');

    PERFORM tests.assert('M23: دوال الحماية SECURITY DEFINER',
        (SELECT count(*) FROM pg_proc WHERE proname IN ('validate_partner_withdrawal','guard_withdrawal_status')
          AND prosecdef) = 2, '');

    PERFORM tests.assert('M23: anon بلا وصول',
        NOT has_table_privilege('anon','public.partner_withdrawals','SELECT')
        AND NOT has_table_privilege('anon','public.partner_audit','SELECT'), '');

    PERFORM tests.assert('M23: authenticated لا يكتب partner_audit',
        NOT has_table_privilege('authenticated','public.partner_audit','INSERT')
        AND NOT has_table_privilege('authenticated','public.partner_audit','UPDATE'), '');

    -- ── B) التجهيز كـsystem_admin ────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);
    INSERT INTO public.partners (id, user_id, name, share_model, percentage) VALUES
        (v_pa, v_admin,  'Partner A', 'percentage', 50),
        (v_pb, NULL,     'Partner B', 'percentage', 30),
        (v_pc, v_worker, 'Partner C', 'percentage', 20);

    INSERT INTO public.profit_distributions (id, farm_id, period_start, period_end) VALUES
        (v_da, v_farmA, DATE '2026-02-01', DATE '2026-02-28'),
        (v_db, v_farmB, DATE '2026-01-01', DATE '2026-01-31');

    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES (v_w1, v_pa, v_farmA, 100, v_admin);
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES (v_w4, v_pb, v_farmB, 50, v_sys);
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES (v_wa, v_pc, v_farmA, 10, v_worker);
    PERFORM tests.assert('M23: system_admin يُدخل طلبات سحب', true, '');

    -- ── C) الشريك يرى سجله ويُنشئ pending فقط ────────────────────────────────
    PERFORM tests.set_user(v_admin);
    SELECT count(*) INTO v_n FROM public.partner_withdrawals WHERE partner_id = v_pa;
    PERFORM tests.assert('M23: المدير-الشريك يرى سحب P_A', v_n = 1, format('n=%s', v_n));

    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES (v_w2, v_pa, v_farmA, 25, v_admin);
    PERFORM tests.assert('M23: الشريك يُنشئ طلب pending لنفسه', true, '');

    BEGIN
        INSERT INTO public.partner_withdrawals (partner_id, farm_id, amount, requested_by, status)
            VALUES (v_pa, v_farmA, 5, v_admin, 'approved');
        PERFORM tests.assert('M23: الشريك لا يُنشئ طلباً معتمداً', false, 'نجح الإنشاء');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M23: الشريك لا يُنشئ طلباً معتمداً', true, SQLERRM);
    END;

    BEGIN
        INSERT INTO public.partner_withdrawals (partner_id, farm_id, amount, requested_by)
            VALUES (v_pb, v_farmA, 5, v_admin);
        PERFORM tests.assert('M23: الشريك لا يُنشئ لشريك آخر', false, 'نجح الإنشاء');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M23: الشريك لا يُنشئ لشريك آخر', true, SQLERRM);
    END;

    SELECT count(*) INTO v_n FROM public.partner_withdrawals;
    PERFORM tests.assert('M23: المدير يرى كل سحب مزرعته (A)', v_n = 3, format('n=%s', v_n));

    -- ── D) العامل-الشريك: self فقط ───────────────────────────────────────────
    PERFORM tests.set_user(v_worker);
    SELECT count(*) INTO v_n FROM public.partner_withdrawals;
    PERFORM tests.assert('M23: العامل-الشريك يرى سحبه فقط', v_n = 1, format('n=%s', v_n));

    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES (v_w3, v_pc, v_farmA, 7, v_worker);
    PERFORM tests.assert('M23: العامل-الشريك يُنشئ طلب pending لنفسه', true, '');

    BEGIN
        INSERT INTO public.partner_withdrawals (partner_id, farm_id, amount, requested_by)
            VALUES (v_pa, v_farmA, 5, v_worker);
        PERFORM tests.assert('M23: العامل لا يُنشئ لشريك آخر', false, 'نجح الإنشاء');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M23: العامل لا يُنشئ لشريك آخر', true, SQLERRM);
    END;

    -- ── E) مدير مزرعة أخرى لا يرى ولا يعدّل ────────────────────────────────
    PERFORM tests.set_user(v_adminB);
    SELECT count(*) INTO v_n FROM public.partner_withdrawals;
    PERFORM tests.assert('M23: مدير B يرى سحب B فقط', v_n = 1, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partner_withdrawals WHERE farm_id = v_farmA;
    PERFORM tests.assert('M23: مدير B لا يرى سحب A', v_n = 0, format('n=%s', v_n));

    -- ── F) system_admin يرى الكل ────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);
    SELECT count(*) INTO v_n FROM public.partner_withdrawals;
    PERFORM tests.assert('M23: system_admin يرى كل السحوبات', v_n = 5, format('n=%s', v_n));

    -- ── G) سلّم الحالات ──────────────────────────────────────────────────────
    UPDATE public.partner_withdrawals SET status='approved' WHERE id=v_w1;
    PERFORM tests.assert('M23: pending -> approved مسموح', true, '');

    UPDATE public.partner_withdrawals SET status='paid' WHERE id=v_w1;
    SELECT count(*) INTO v_n FROM public.partner_withdrawals
     WHERE id=v_w1 AND status='paid' AND paid_at IS NOT NULL;
    PERFORM tests.assert('M23: approved -> paid مسموح ويُختم paid_at', v_n = 1, '');

    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES (v_w5, v_pa, v_farmA, 11, v_sys);
    BEGIN
        UPDATE public.partner_withdrawals SET status='paid' WHERE id=v_w5;
        PERFORM tests.assert('M23: pending -> paid مباشرة مرفوض', false, 'مرّ الانتقال');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M23: pending -> paid مباشرة مرفوض', true, SQLERRM);
    END;

    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES (v_w6, v_pa, v_farmA, 12, v_sys);
    BEGIN
        UPDATE public.partner_withdrawals SET status='rejected' WHERE id=v_w6;
        PERFORM tests.assert('M23: rejected بلا سبب مرفوض', false, 'مرّ دون سبب');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M23: rejected بلا سبب مرفوض', true, SQLERRM);
    END;

    UPDATE public.partner_withdrawals SET status='rejected', rejection_reason='رفض إداري' WHERE id=v_w6;
    SELECT count(*) INTO v_n FROM public.partner_withdrawals
     WHERE id=v_w6 AND status='rejected' AND reviewed_at IS NOT NULL;
    PERFORM tests.assert('M23: rejected مع سبب مسموح ويُختم reviewed_at', v_n = 1, '');

    -- ── H) ربط التوزيع بنفس المزرعة ─────────────────────────────────────────
    BEGIN
        INSERT INTO public.partner_withdrawals (partner_id, farm_id, amount, requested_by, distribution_id)
            VALUES (v_pa, v_farmA, 9, v_sys, v_db);
        PERFORM tests.assert('M23: توزيع مزرعة أخرى مرفوض', false, 'نجح الربط');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M23: توزيع مزرعة أخرى مرفوض', true, SQLERRM);
    END;

    INSERT INTO public.partner_withdrawals (partner_id, farm_id, amount, requested_by, distribution_id)
        VALUES (v_pa, v_farmA, 9, v_sys, v_da);
    PERFORM tests.assert('M23: ربط توزيع نفس المزرعة مسموح', true, '');

    -- ── I) المدير يعدّل سحب مزرعته ──────────────────────────────────────────
    PERFORM tests.set_user(v_admin);
    UPDATE public.partner_withdrawals SET status='approved', reviewed_by=v_admin WHERE id=v_w2;
    SELECT count(*) INTO v_n FROM public.partner_withdrawals WHERE id=v_w2 AND status='approved';
    PERFORM tests.assert('M23: المدير يعتمد سحب مزرعته', v_n = 1, '');

    -- ── J) العامل لا يستطيع تعديل سحب غيره ──────────────────────────────────
    PERFORM tests.set_user(v_worker);
    UPDATE public.partner_withdrawals SET status='rejected', rejection_reason='x' WHERE id=v_w2;
    PERFORM tests.set_user(v_sys);
    SELECT count(*) INTO v_n FROM public.partner_withdrawals WHERE id=v_w2 AND status='approved';
    PERFORM tests.assert('M23: العامل لا يعدّل سحب غيره (RLS تحجبه)', v_n = 1, '');

    RAISE NOTICE 'p0_partner_withdrawals: انتهى الجزء الأول';
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_partner_withdrawals: كل الفحوص PASS — العزل، السلّم، الحماية';
END; $final$;

ROLLBACK;
