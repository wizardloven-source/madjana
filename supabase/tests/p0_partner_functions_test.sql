-- ============================================================================
--  p0_partner_functions_test.sql
--  خطة W6-M24: دوال سير عمل الشركاء
--  الاختبار يعمل كـtest_runner (بدون BYPASSRLS) عبر run_all.py، لذا كل فحص
--  صلاحيات حقيقي. كل شيء داخل BEGIN ... ROLLBACK ولا يمسّ بيانات دائمة.
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

    v_pa  uuid := '11111111-0000-0000-0000-0000000000a1';
    v_pb  uuid := '11111111-0000-0000-0000-0000000000b1';
    v_pc  uuid := '11111111-0000-0000-0000-0000000000c1';
    v_pd  uuid := '11111111-0000-0000-0000-0000000000d1';
    v_ps1 uuid := '11111111-0000-0000-0000-0000000000e1';
    v_ps2 uuid := '11111111-0000-0000-0000-0000000000f1';
    v_pe  uuid := '11111111-0000-0000-0000-000000000091';

    v_fl1 uuid := '44444444-0000-0000-0000-0000000000a1';
    v_fl2 uuid := '44444444-0000-0000-0000-0000000000b1';
    v_ghost uuid := 'ffffffff-0000-0000-0000-0000000000ff';

    v_w1 uuid := '33333333-0000-0000-0000-0000000000a1';  -- pending 100
    v_w2 uuid := '33333333-0000-0000-0000-0000000000a2';  -- approved 50
    v_w3 uuid := '33333333-0000-0000-0000-0000000000a3';  -- paid 30
    v_w4 uuid := '33333333-0000-0000-0000-0000000000a4';  -- rejected 20
    v_w5 uuid := '33333333-0000-0000-0000-0000000000a5';  -- to approve 77

    v_pstart date := date_trunc('month', CURRENT_DATE)::date;
    v_pend   date := CURRENT_DATE;

    v_n numeric;
    v_cnt int;
    v_status text;
    v_reviewer uuid;
    v_row record;
    v_ok boolean;
BEGIN
    -- ── A) البنية والصلاحيات ────────────────────────────────────────────────
    PERFORM tests.assert('M24: الدوال الخمس موجودة',
        (SELECT count(*) FROM pg_proc p
          WHERE p.oid IN (to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'),
                          to_regprocedure('public.partner_pending_withdrawal(uuid)'),
                          to_regprocedure('public.partner_summary(uuid)'),
                          to_regprocedure('public.approve_withdrawal(uuid,uuid)'),
                          to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)'))) = 5, '');

    PERFORM tests.assert('M24: كل الدوال SECURITY DEFINER',
        (SELECT count(*) FROM pg_proc p
          WHERE p.oid IN (to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'),
                          to_regprocedure('public.partner_pending_withdrawal(uuid)'),
                          to_regprocedure('public.partner_summary(uuid)'),
                          to_regprocedure('public.approve_withdrawal(uuid,uuid)'),
                          to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)'))
            AND p.prosecdef) = 5, '');

    PERFORM tests.assert('M24: search_path مثبّت على الخمس',
        (SELECT count(*) FROM pg_proc p
          WHERE p.oid IN (to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'),
                          to_regprocedure('public.partner_pending_withdrawal(uuid)'),
                          to_regprocedure('public.partner_summary(uuid)'),
                          to_regprocedure('public.approve_withdrawal(uuid,uuid)'),
                          to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)'))
            AND EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%')) = 5, '');

    PERFORM tests.assert('M24: partner_summary/calculate ترجع صفوفاً',
        (SELECT proretset FROM pg_proc WHERE oid = to_regprocedure('public.partner_summary(uuid)'))
        AND (SELECT proretset FROM pg_proc WHERE oid = to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)')), '');

    PERFORM tests.assert('M24: partner_net_profit ترجع قيمة مفردة',
        NOT (SELECT proretset FROM pg_proc WHERE oid = to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)')), '');

    PERFORM tests.assert('M24: anon لا ينفّذ أي دالة',
        NOT has_function_privilege('anon', 'public.partner_net_profit(uuid,date,date,uuid)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'public.partner_pending_withdrawal(uuid)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'public.partner_summary(uuid)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'public.approve_withdrawal(uuid,uuid)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'public.calculate_profit_distribution(uuid,date,date,uuid)', 'EXECUTE'), '');

    PERFORM tests.assert('M24: authenticated ينفّذ كل الدوال',
        has_function_privilege('authenticated', 'public.partner_net_profit(uuid,date,date,uuid)', 'EXECUTE')
        AND has_function_privilege('authenticated', 'public.partner_pending_withdrawal(uuid)', 'EXECUTE')
        AND has_function_privilege('authenticated', 'public.partner_summary(uuid)', 'EXECUTE')
        AND has_function_privilege('authenticated', 'public.approve_withdrawal(uuid,uuid)', 'EXECUTE')
        AND has_function_privilege('authenticated', 'public.calculate_profit_distribution(uuid,date,date,uuid)', 'EXECUTE'), '');

    PERFORM tests.assert('M24: لا صلاحية EXECUTE لـPUBLIC (grantee 0)',
        NOT EXISTS (
            SELECT 1 FROM pg_proc p
            CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
             WHERE p.oid IN (to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'),
                             to_regprocedure('public.partner_pending_withdrawal(uuid)'),
                             to_regprocedure('public.partner_summary(uuid)'),
                             to_regprocedure('public.approve_withdrawal(uuid,uuid)'),
                             to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)'))
               AND a.grantee = 0), '');

    -- ── B) التجهيز كـsystem_admin ────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);

    INSERT INTO public.partners (id, user_id, name, share_model, percentage) VALUES
        (v_pa, v_admin, 'A Pct 50', 'percentage', 50),
        (v_pb, NULL,    'B Pct 30', 'percentage', 30),
        (v_pc, v_worker,'C Pct 20', 'percentage', 20);

    INSERT INTO public.partners (id, name, share_model, salary_amount, salary_period)
        VALUES (v_pd, 'D Salary', 'salary', 500, 'monthly');

    INSERT INTO public.partners (id, name, share_model, shares) VALUES
        (v_ps1, 'E Shares 30', 'shares', 30),
        (v_ps2, 'F Shares 70', 'shares', 70);

    INSERT INTO public.partners (id, name, share_model, shares, salary_amount, salary_period)
        VALUES (v_pe, 'G Mixed', 'mixed', 100, 100, 'monthly');

    INSERT INTO public.flocks (id, farm_id, breed, initial_count, current_count, start_date)
        VALUES (v_fl1, v_farmA, 'M24 Flock A', 100, 100, v_pstart),
               (v_fl2, v_farmB, 'M24 Flock B', 100, 100, v_pstart);

    INSERT INTO public.revenue (farm_id, date, category, amount, currency) VALUES
        (v_farmA, v_pend, 'other', 1000, 'dollar');
    INSERT INTO public.expenses (farm_id, date, category, amount, currency) VALUES
        (v_farmA, v_pend, 'other', 400, 'dollar');
    INSERT INTO public.revenue (farm_id, date, category, amount, currency, flock_id) VALUES
        (v_farmA, v_pend, 'other', 300, 'dollar', v_fl1);
    INSERT INTO public.expenses (farm_id, date, category, amount, currency, flock_id) VALUES
        (v_farmA, v_pend, 'other', 100, 'dollar', v_fl1);
    PERFORM tests.assert('M24: تجهيز الشراكات والمزرعة والقطيع', true, '');

    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by, status)
        VALUES (v_w1, v_pa, v_farmA, 100, v_sys, 'pending');
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by, status, reviewed_by)
        VALUES (v_w2, v_pa, v_farmA, 50, v_sys, 'approved', v_sys);
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by, status, paid_at)
        VALUES (v_w3, v_pa, v_farmA, 30, v_sys, 'paid', now());
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by, status, rejection_reason)
        VALUES (v_w4, v_pa, v_farmA, 20, v_sys, 'rejected', 'x');
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by, status)
        VALUES (v_w5, v_pa, v_farmA, 77, v_sys, 'pending');
    PERFORM tests.assert('M24: تجهيز طلبات السحب', true, '');

    -- ── C) partner_net_profit — القيم (كـsystem_admin) ───────────────────────
    v_n := public.partner_net_profit(v_pa, v_pstart, v_pend, NULL);
    PERFORM tests.assert('M24: net_profit PA نسبة 50% من 800', v_n = 400, format('n=%s', v_n));

    v_n := public.partner_net_profit(v_pa, v_pstart, v_pend, v_fl1);
    PERFORM tests.assert('M24: net_profit PA على القطيع 50% من 200', v_n = 100, format('n=%s', v_n));

    v_n := public.partner_net_profit(v_pb, v_pstart, v_pend, NULL);
    PERFORM tests.assert('M24: net_profit PB 30%', v_n = 240, format('n=%s', v_n));

    v_n := public.partner_net_profit(v_pc, v_pstart, v_pend, NULL);
    PERFORM tests.assert('M24: net_profit PC 20%', v_n = 160, format('n=%s', v_n));

    v_n := public.partner_net_profit(v_pd, v_pstart, v_pend, NULL);
    PERFORM tests.assert('M24: net_profit PD راتب فقط = 500', v_n = 500, format('n=%s', v_n));

    v_n := public.partner_net_profit(v_ps1, v_pstart, v_pend, v_fl1);
    PERFORM tests.assert('M24: net_profit PS1 أسهم 30/200 من 200', v_n = 30, format('n=%s', v_n));

    v_n := public.partner_net_profit(v_ps2, v_pstart, v_pend, v_fl1);
    PERFORM tests.assert('M24: net_profit PS2 أسهم 70/200 من 200', v_n = 70, format('n=%s', v_n));

    v_n := public.partner_net_profit(v_pe, v_pstart, v_pend, v_fl1);
    PERFORM tests.assert('M24: net_profit PE مختلط = حصة + راتب', v_n = 200, format('n=%s', v_n));

    v_n := public.partner_net_profit(v_pe, v_pstart, v_pend, NULL);
    PERFORM tests.assert('M24: net_profit PE مختلط على المزرعة', v_n = 500, format('n=%s', v_n));

    -- ── D) partner_net_profit — الأخطاء ──────────────────────────────────────
    BEGIN
        PERFORM public.partner_net_profit(v_pa, v_pend, v_pstart, NULL);
        PERFORM tests.assert('M24: فترة مقلوبة مرفوضة', false, 'مرّت');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: فترة مقلوبة مرفوضة', SQLERRM LIKE '%INVALID_PERIOD%', SQLERRM);
    END;

    BEGIN
        PERFORM public.partner_net_profit(v_pa, NULL, v_pend, NULL);
        PERFORM tests.assert('M24: فترة ناقصة مرفوضة', false, 'مرّت');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: فترة ناقصة مرفوضة', SQLERRM LIKE '%INVALID_PERIOD%', SQLERRM);
    END;

    BEGIN
        PERFORM public.partner_net_profit(v_ghost, v_pstart, v_pend, NULL);
        PERFORM tests.assert('M24: شريك غير موجود مرفوض', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: شريك غير موجود مرفوض', SQLERRM LIKE '%PARTNER_NOT_FOUND%', SQLERRM);
    END;

    BEGIN
        PERFORM public.partner_net_profit(v_pa, v_pstart, v_pend, v_ghost);
        PERFORM tests.assert('M24: قطيع غير موجود مرفوض', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: قطيع غير موجود مرفوض', SQLERRM LIKE '%FLOCK_NOT_FOUND%', SQLERRM);
    END;

    -- ── E) partner_pending_withdrawal ────────────────────────────────────────
    v_n := public.partner_pending_withdrawal(v_pa);
    PERFORM tests.assert('M24: pending = pending+approved (100+50+77)', v_n = 227, format('n=%s', v_n));

    BEGIN
        PERFORM public.partner_pending_withdrawal(v_ghost);
        PERFORM tests.assert('M24: pending لشريك غير موجود مرفوض', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: pending لشريك غير موجود مرفوض', SQLERRM LIKE '%PARTNER_NOT_FOUND%', SQLERRM);
    END;

    -- ── F) approve_withdrawal — الصلاحية والحالة ─────────────────────────────
    PERFORM tests.set_user(v_worker);
    BEGIN
        PERFORM public.approve_withdrawal(v_w5, v_worker);
        PERFORM tests.assert('M24: العامل لا يعتمد', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: العامل لا يعتمد', SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    PERFORM tests.set_user(v_adminB);
    BEGIN
        PERFORM public.approve_withdrawal(v_w5, v_adminB);
        PERFORM tests.assert('M24: مدير مزرعة أخرى لا يعتمد', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: مدير مزرعة أخرى لا يعتمد', SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    PERFORM tests.set_user(v_admin);
    PERFORM public.approve_withdrawal(v_w5, v_admin);
    SELECT status, reviewed_by INTO v_status, v_reviewer
      FROM public.partner_withdrawals WHERE id = v_w5;
    PERFORM tests.assert('M24: مدير المزرعة يعتمد -> approved',
        v_status = 'approved' AND v_reviewer = v_admin, format('status=%s', v_status));

    PERFORM tests.assert('M24: reviewed_at خُتم عند الاعتماد',
        (SELECT reviewed_at IS NOT NULL FROM public.partner_withdrawals WHERE id = v_w5), '');

    BEGIN
        PERFORM public.approve_withdrawal(v_w5, v_admin);
        PERFORM tests.assert('M24: اعتماد طلب معتمد مرفوض', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: اعتماد طلب معتمد مرفوض', SQLERRM LIKE '%INVALID_STATUS_TRANSITION%', SQLERRM);
    END;

    BEGIN
        PERFORM public.approve_withdrawal(v_ghost, v_admin);
        PERFORM tests.assert('M24: اعتماد طلب غير موجود مرفوض', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: اعتماد طلب غير موجود مرفوض', SQLERRM LIKE '%WITHDRAWAL_NOT_FOUND%', SQLERRM);
    END;

    -- ── G) partner_summary ───────────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);
    SELECT * INTO v_row FROM public.partner_summary(v_pa);
    PERFORM tests.assert('M24: ملخص PA — الاسم',
        v_row.name = 'A Pct 50', format('name=%s', v_row.name));
    PERFORM tests.assert('M24: ملخص PA — النموذج وقيمته',
        v_row.share_model = 'percentage' AND v_row.share_value = 50, format('m=%s v=%s', v_row.share_model, v_row.share_value));
    PERFORM tests.assert('M24: ملخص PA — صافي الربح 400',
        v_row.net_profit = 400, format('net=%s', v_row.net_profit));
    PERFORM tests.assert('M24: ملخص PA — المعلّق 227',
        v_row.pending = 227, format('pending=%s', v_row.pending));
    PERFORM tests.assert('M24: ملخص PA — المدفوع 30',
        v_row.paid = 30, format('paid=%s', v_row.paid));

    SELECT * INTO v_row FROM public.partner_summary(v_pd);
    PERFORM tests.assert('M24: ملخص PD — قيمة الراتب',
        v_row.share_model = 'salary' AND v_row.share_value = 500, format('v=%s', v_row.share_value));

    -- المدير-الشريك يقرأ ملخص نفسه
    PERFORM tests.set_user(v_admin);
    SELECT * INTO v_row FROM public.partner_summary(v_pa);
    PERFORM tests.assert('M24: المدير-الشريك يقرأ ملخص نفسه', v_row.net_profit = 400, '');

    -- العامل ليس له وصول لملخص شريك آخر
    PERFORM tests.set_user(v_worker);
    BEGIN
        SELECT count(*) INTO v_cnt FROM public.partner_summary(v_pa);
        PERFORM tests.assert('M24: العامل لا يقرأ ملخص PA', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: العامل لا يقرأ ملخص PA', SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    -- ── H) calculate_profit_distribution ─────────────────────────────────────
    PERFORM tests.set_user(v_worker);
    BEGIN
        SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL);
        PERFORM tests.assert('M24: العامل لا يحسب التوزيع', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: العامل لا يحسب التوزيع', SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    PERFORM tests.set_user(v_adminB);
    BEGIN
        SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL);
        PERFORM tests.assert('M24: مدير مزرعة أخرى لا يحسب', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: مدير مزرعة أخرى لا يحسب', SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    PERFORM tests.set_user(v_sys);
    SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL);
    PERFORM tests.assert('M24: التوزيع يعيد صفاً لكل شريك نشط (7)', v_cnt = 7, format('n=%s', v_cnt));

    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_pa;
    PERFORM tests.assert('M24: التوزيع PA = 400', v_n = 400, format('n=%s', v_n));

    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_pb;
    PERFORM tests.assert('M24: التوزيع PB = 240', v_n = 240, format('n=%s', v_n));

    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_pd;
    PERFORM tests.assert('M24: التوزيع PD راتب 500', v_n = 500, format('n=%s', v_n));

    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_ps1;
    PERFORM tests.assert('M24: التوزيع PS1 = 120 (أسهم)', v_n = 120, format('n=%s', v_n));

    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_pe;
    PERFORM tests.assert('M24: التوزيع PE = 500 (مختلط)', v_n = 500, format('n=%s', v_n));

    SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, v_fl1);
    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, v_fl1)
     WHERE partner_id = v_pa;
    PERFORM tests.assert('M24: التوزيع على القطيع PA = 100',
        v_cnt = 7 AND v_n = 100, format('n=%s', v_n));

    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, v_fl1)
     WHERE partner_id = v_pe;
    PERFORM tests.assert('M24: التوزيع على القطيع PE = 200', v_n = 200, format('n=%s', v_n));

    -- ── I) calculate — الأخطاء ───────────────────────────────────────────────
    BEGIN
        SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_ghost, v_pstart, v_pend, NULL);
        PERFORM tests.assert('M24: مزرعة غير موجودة مرفوضة', false, 'مرّت');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: مزرعة غير موجودة مرفوضة', SQLERRM LIKE '%FARM_NOT_FOUND%', SQLERRM);
    END;

    BEGIN
        SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, v_fl2);
        PERFORM tests.assert('M24: قطيع مزرعة أخرى مرفوض', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: قطيع مزرعة أخرى مرفوض', SQLERRM LIKE '%FLOCK_FARM_MISMATCH%', SQLERRM);
    END;

    BEGIN
        SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pend, v_pstart, NULL);
        PERFORM tests.assert('M24: توزيع فترة مقلوبة مرفوض', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: توزيع فترة مقلوبة مرفوض', SQLERRM LIKE '%INVALID_PERIOD%', SQLERRM);
    END;

    -- مجموع النسب > 100
    UPDATE public.partners SET percentage = 60 WHERE id = v_pc;
    BEGIN
        SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL);
        PERFORM tests.assert('M24: مجموع النسب > 100 مرفوض', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: مجموع النسب > 100 مرفوض', SQLERRM LIKE '%INVALID_PERCENTAGES%', SQLERRM);
    END;
    UPDATE public.partners SET percentage = 20 WHERE id = v_pc;

    -- عملات مختلطة
    INSERT INTO public.revenue (farm_id, date, category, amount, currency)
        VALUES (v_farmA, v_pend, 'other', 5, 'lira');
    BEGIN
        SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL);
        PERFORM tests.assert('M24: عملات مختلطة مرفوضة (توزيع)', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: عملات مختلطة مرفوضة (توزيع)', SQLERRM LIKE '%MIXED_CURRENCY%', SQLERRM);
    END;
    BEGIN
        PERFORM public.partner_net_profit(v_pa, v_pstart, v_pend, NULL);
        PERFORM tests.assert('M24: عملات مختلطة مرفوضة (net_profit)', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M24: عملات مختلطة مرفوضة (net_profit)', SQLERRM LIKE '%MIXED_CURRENCY%', SQLERRM);
    END;
    DELETE FROM public.revenue
     WHERE farm_id = v_farmA AND currency = 'lira' AND date = v_pend;

    v_n := public.partner_net_profit(v_pa, v_pstart, v_pend, NULL);
    PERFORM tests.assert('M24: بعد إزالة العملة الثانية يعود net_profit=400', v_n = 400, format('n=%s', v_n));

    RAISE NOTICE 'p0_partner_functions: انتهى';
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_partner_functions: كل الفحوص PASS — القيم، الصلاحيات، الأخطاء';
END; $final$;

ROLLBACK;
