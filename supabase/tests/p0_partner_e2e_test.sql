-- ============================================================================
--  p0_partner_e2e_test.sql
--  W6-M27: end-to-end partnership lifecycle
--  إنشاء شريك -> توزيع أرباح (رأس + بنود) -> معاينة -> طلب سحب -> اعتماد ->
--  صرف -> ملخص + تدقيق. تُشغَّل كـtest_runner (بلا BYPASSRLS) لداخل
--  BEGIN ... ROLLBACK، فلا تترك أثراً.
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
    v_farmA   uuid := '00000000-0000-0000-0000-000000000001';

    v_pa  uuid := '11111111-0000-0000-0000-0000000000a1';  -- manager-partner 60%
    v_pb  uuid := '11111111-0000-0000-0000-0000000000b1';  -- worker-partner 40%

    v_dist uuid := '22222222-0000-0000-0000-0000000000a1';
    v_ddpa uuid := '66666666-0000-0000-0000-0000000000a1';
    v_ddpb uuid := '66666666-0000-0000-0000-0000000000a2';
    v_w    uuid := '33333333-0000-0000-0000-0000000000a1';

    v_pstart date := date_trunc('month', CURRENT_DATE)::date;
    v_pend   date := CURRENT_DATE;

    v_n numeric;
    v_cnt int;
    v_status text;
    v_at timestamptz;
    v_by uuid;
    v_row record;
BEGIN
    -- ── A) التجهيز كـsystem_admin: شركاء + مزرعة + عائد/مصروف ────────────────
    PERFORM tests.set_user(v_sys);

    INSERT INTO public.partners (id, user_id, name, share_model, percentage) VALUES
        (v_pa, v_admin,  'E2E Manager 60', 'percentage', 60),
        (v_pb, v_worker, 'E2E Worker 40',  'percentage', 40);

    INSERT INTO public.revenue (farm_id, date, category, amount, currency)
        VALUES (v_farmA, v_pend, 'other', 1000, 'dollar');
    INSERT INTO public.expenses (farm_id, date, category, amount, currency)
        VALUES (v_farmA, v_pend, 'other', 400, 'dollar');

    SELECT count(*) INTO v_cnt FROM public.partners WHERE id IN (v_pa, v_pb);
    PERFORM tests.assert('E2E: إنشاء الشريكين', v_cnt = 2, format('n=%s', v_cnt));

    -- ── B) إنشاء رأس التوزيع + بنوده ─────────────────────────────────────────
    INSERT INTO public.profit_distributions
        (id, farm_id, period_start, period_end, label, status, currency,
         total_revenue, total_expenses, net_profit, reserve_amount, distributable_profit, approved_by, approved_at)
        VALUES
        (v_dist, v_farmA, v_pstart, v_pend, 'E2E', 'draft', 'dollar',
         1000, 400, 600, 100, 500, NULL, NULL);

    INSERT INTO public.profit_distribution_details
        (id, distribution_id, farm_id, partner_id, share_model, percentage, profit_share, net_amount)
        VALUES
        (v_ddpa, v_dist, v_farmA, v_pa, 'percentage', 60, 360, 360),
        (v_ddpb, v_dist, v_farmA, v_pb, 'percentage', 40, 240, 240);

    SELECT distributable_profit, status INTO v_n, v_status
      FROM public.profit_distributions WHERE id = v_dist;
    PERFORM tests.assert('E2E: رأس التوزيع مخزّن والرياضيات مقبولة (500/600)',
        v_n = 500 AND v_status = 'draft', format('d=%s s=%s', v_n, v_status));

    SELECT net_amount INTO v_n FROM public.profit_distribution_details WHERE id = v_ddpa;
    PERFORM tests.assert('E2E: بند الشريك-المدير net_amount=360', v_n = 360, format('v=%s', v_n));
    SELECT net_amount INTO v_n FROM public.profit_distribution_details WHERE id = v_ddpb;
    PERFORM tests.assert('E2E: بند الشريك-العامل net_amount=240', v_n = 240, format('v=%s', v_n));

    -- ── C) معاينة calculate_profit_distribution تطابق البنود ─────────────────
    PERFORM tests.set_user(v_admin);   -- مدير المزرعة
    SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL);
    PERFORM tests.assert('E2E: المعاينة تعيد صفاً لكل شريك (2)', v_cnt = 2, format('n=%s', v_cnt));

    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_pa;
    PERFORM tests.assert('E2E: المعاينة تطابق بند PA (360)', v_n = 360, format('v=%s', v_n));
    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_pb;
    PERFORM tests.assert('E2E: المعاينة تطابق بند PB (240)', v_n = 240, format('v=%s', v_n));

    -- ── D) الشريك-المدير يقرأ شريكه، والشريك-العامل يرى بنده فقط ─────────────
    SELECT count(*) INTO v_cnt FROM public.partners;
    PERFORM tests.assert('E2E: مدير المزرعة يرى الشريكين (كلاهما له بند بالمزرعة)',
        v_cnt = 2, format('n=%s', v_cnt));

    PERFORM tests.set_user(v_worker);   -- الشريك-العامل
    SELECT count(*) INTO v_cnt FROM public.profit_distribution_details;
    PERFORM tests.assert('E2E: الشريك-العامل يرى بنده فقط', v_cnt = 1, format('n=%s', v_cnt));
    SELECT count(*) INTO v_cnt FROM public.profit_distribution_details WHERE partner_id = v_pa;
    PERFORM tests.assert('E2E: الشريك-العامل لا يرى بند شريك آخر', v_cnt = 0, format('n=%s', v_cnt));
    SELECT count(*) INTO v_cnt FROM public.profit_distributions;
    PERFORM tests.assert('E2E: الشريك يرى رأس التوزيع الذي له فيه بند', v_cnt = 1, format('n=%s', v_cnt));

    -- ── E) طلب سحب من الشريك نفسه ────────────────────────────────────────────
    INSERT INTO public.partner_withdrawals
        (id, partner_id, farm_id, distribution_id, amount, requested_by, status)
        VALUES (v_w, v_pb, v_farmA, v_dist, 100, v_worker, 'pending');

    v_n := public.partner_pending_withdrawal(v_pb);
    PERFORM tests.assert('E2E: معلّق الشريك بعد الطلب = 100', v_n = 100, format('n=%s', v_n));

    SELECT * INTO v_row FROM public.partner_summary(v_pb);
    PERFORM tests.assert('E2E: ملخص الشريك قبل الصرف — الصافي 240', v_row.net_profit = 240, format('net=%s', v_row.net_profit));
    PERFORM tests.assert('E2E: ملخص الشريك قبل الصرف — معلّق 100', v_row.pending = 100, format('p=%s', v_row.pending));
    PERFORM tests.assert('E2E: ملخص الشريك قبل الصرف — مدفوع 0', v_row.paid = 0, format('paid=%s', v_row.paid));

    -- ── F) الاعتماد من المدير ────────────────────────────────────────────────
    PERFORM tests.set_user(v_admin);
    PERFORM public.approve_withdrawal(v_w, v_admin);

    SELECT status, reviewed_at, reviewed_by INTO v_status, v_at, v_by
      FROM public.partner_withdrawals WHERE id = v_w;
    PERFORM tests.assert('E2E: المدير يعتمد الطلب -> approved',
        v_status = 'approved', format('s=%s', v_status));
    PERFORM tests.assert('E2E: reviewed_at خُتم عند الاعتماد', v_at IS NOT NULL, '');
    PERFORM tests.assert('E2E: reviewed_by = المدير', v_by = v_admin, '');

    BEGIN
        PERFORM public.approve_withdrawal(v_w, v_admin);
        PERFORM tests.assert('E2E: إعادة اعتماد طلب معتمد مرفوضة', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('E2E: إعادة اعتماد طلب معتمد مرفوضة',
            SQLERRM LIKE '%INVALID_STATUS_TRANSITION%', SQLERRM);
    END;

    PERFORM tests.set_user(v_worker);
    v_n := public.partner_pending_withdrawal(v_pb);
    PERFORM tests.assert('E2E: المعتمد يبقى ضمن المعلّق (100)', v_n = 100, format('n=%s', v_n));

    -- ── G) الصرف من المدير (approved -> paid) ───────────────────────────────
    PERFORM tests.set_user(v_admin);
    UPDATE public.partner_withdrawals SET status = 'paid', payment_method = 'cash' WHERE id = v_w;
    GET DIAGNOSTICS v_cnt = ROW_COUNT;
    PERFORM tests.assert('E2E: المدير يصرف الطلب (صف واحد)', v_cnt = 1, format('n=%s', v_cnt));

    SELECT status, paid_at INTO v_status, v_at FROM public.partner_withdrawals WHERE id = v_w;
    PERFORM tests.assert('E2E: الحالة paid و paid_at خُتم', v_status = 'paid' AND v_at IS NOT NULL,
        format('s=%s', v_status));

    -- ── H) الملخص بعد الصرف ──────────────────────────────────────────────────
    PERFORM tests.set_user(v_worker);
    SELECT * INTO v_row FROM public.partner_summary(v_pb);
    PERFORM tests.assert('E2E: الملخص بعد الصرف — معلّق 0', v_row.pending = 0, format('p=%s', v_row.pending));
    PERFORM tests.assert('E2E: الملخص بعد الصرف — مدفوع 100', v_row.paid = 100, format('paid=%s', v_row.paid));
    PERFORM tests.assert('E2E: الملخص بعد الصرف — الصافي ثابت 240', v_row.net_profit = 240, format('net=%s', v_row.net_profit));
    v_n := public.partner_pending_withdrawal(v_pb);
    PERFORM tests.assert('E2E: معلّق الشريك صفر بعد الصرف', v_n = 0, format('n=%s', v_n));

    -- ── I) مسار التدقيق الكامل (عبر الكاتب الخادمي فقط) ─────────────────────
    PERFORM tests.set_user(v_sys);
    PERFORM public.record_partner_audit(v_farmA, 'distribution_created', v_sys,
        NULL, NULL, jsonb_build_object('distribution_id', v_dist));
    PERFORM public.record_partner_audit(v_farmA, 'withdrawal_paid', v_sys,
        v_pb, jsonb_build_object('status', 'approved'), jsonb_build_object('status', 'paid'));

    -- W7.4: محفّز trg_partner_withdrawals_audit يضيف 3 سطور تلقائية
    -- (requested + approved + paid لطلب v_w) إلى السطرين اليدويين أعلاه.
    SELECT count(*) INTO v_cnt FROM public.partner_audit;
    PERFORM tests.assert('E2E: system_admin يرى كل التدقيق (2 يدوي + 3 محفّز)', v_cnt = 5, format('n=%s', v_cnt));

    PERFORM tests.set_user(v_admin);
    SELECT count(*) INTO v_cnt FROM public.partner_audit WHERE farm_id = v_farmA;
    PERFORM tests.assert('E2E: مدير المزرعة يرى تدقيق مزرعته (5)', v_cnt = 5, format('n=%s', v_cnt));

    PERFORM tests.set_user(v_worker);
    SELECT count(*) INTO v_cnt FROM public.partner_audit;
    PERFORM tests.assert('E2E: الشريك-العامل يرى تدقيق شريكه فقط (4)', v_cnt = 4, format('n=%s', v_cnt));
    SELECT count(*) INTO v_cnt FROM public.partner_audit WHERE action = 'distribution_created';
    PERFORM tests.assert('E2E: الشريك لا يرى تدقيقاً بلا partner_id له (0)', v_cnt = 0, format('n=%s', v_cnt));

    RAISE NOTICE 'p0_partner_e2e: انتهى — الدورة الكاملة (شريك->توزيع->سحب->صرف->تدقيق)';
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_partner_e2e: كل الفحوص PASS — E2E سليم والصلاحيات مطبّقة';
END; $final$;

ROLLBACK;
