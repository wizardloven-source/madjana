-- ============================================================================
--  p0_partner_reports_test.sql
--  W6-M27: partner reporting engine (net profit, distribution preview, summary)
--  يغطّي النماذج الأربعة، حدود الفترة، القطيع، فترة فارغة، ومجموع 100%، وحالات
--  الخطأ (نسب>100، عملات مختلطة، فترة مقلوبة، مزرعة/قطيع غير صالح).
--  يعمل كـtest_runner داخل BEGIN ... ROLLBACK.
--
--  ملاحظة رياضية: الدالتان partner_net_profit و calculate_profit_distribution
--  عند NULL للقطيع تجمعان كل عائدات المزرعة (بما فيها صفوف القطيع)، لذا "صافي
--  المزرعة الكامل" هنا = 1800، و"صافي القطيع" = 300.
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
    v_farmA  uuid := '00000000-0000-0000-0000-000000000001';
    v_farmB  uuid := '00000000-0000-0000-0000-000000000002';

    v_r1 uuid := '11111111-0000-0000-0000-0000000000a1';  -- pct 40
    v_r2 uuid := '11111111-0000-0000-0000-0000000000b1';  -- pct 60
    v_r3 uuid := '11111111-0000-0000-0000-0000000000c1';  -- salary 300
    v_r4 uuid := '11111111-0000-0000-0000-0000000000d1';  -- shares 25
    v_r5 uuid := '11111111-0000-0000-0000-0000000000e1';  -- shares 75
    v_r6 uuid := '11111111-0000-0000-0000-0000000000f1';  -- mixed shares 20 + salary 50

    v_fa uuid := '44444444-0000-0000-0000-0000000000a1';
    v_fb uuid := '44444444-0000-0000-0000-0000000000b1';
    v_ghost uuid := 'ffffffff-0000-0000-0000-0000000000ff';

    v_wp uuid := '33333333-0000-0000-0000-0000000000a1';  -- pending 30
    v_wd uuid := '33333333-0000-0000-0000-0000000000a2';  -- paid 50

    v_pstart date := date_trunc('month', CURRENT_DATE)::date;
    v_pend   date := CURRENT_DATE;

    v_n numeric;
    v_cnt int;
    v_row record;
BEGIN
    -- ── A) البنية والصلاحيات الدنيا ──────────────────────────────────────────
    PERFORM tests.assert('REPORT: الدوال الخمس موجودة',
        (SELECT count(*) FROM pg_proc p
          WHERE p.oid IN (to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'),
                          to_regprocedure('public.partner_pending_withdrawal(uuid)'),
                          to_regprocedure('public.partner_summary(uuid)'),
                          to_regprocedure('public.approve_withdrawal(uuid,uuid)'),
                          to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)'))) = 5, '');
    PERFORM tests.assert('REPORT: كل الدوال SECURITY DEFINER',
        (SELECT count(*) FROM pg_proc p
          WHERE p.oid IN (to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'),
                          to_regprocedure('public.partner_pending_withdrawal(uuid)'),
                          to_regprocedure('public.partner_summary(uuid)'),
                          to_regprocedure('public.approve_withdrawal(uuid,uuid)'),
                          to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)'))
            AND p.prosecdef) = 5, '');

    -- ── B) التجهيز كـsystem_admin ────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);

    INSERT INTO public.partners (id, user_id, name, share_model, percentage) VALUES
        (v_r1, v_admin, 'R1 Pct 40', 'percentage', 40),
        (v_r2, NULL,    'R2 Pct 60', 'percentage', 60);
    INSERT INTO public.partners (id, name, share_model, salary_amount, salary_period) VALUES
        (v_r3, 'R3 Salary', 'salary', 300, 'monthly');
    INSERT INTO public.partners (id, name, share_model, shares) VALUES
        (v_r4, 'R4 Shares 25', 'shares', 25),
        (v_r5, 'R5 Shares 75', 'shares', 75);
    INSERT INTO public.partners (id, name, share_model, shares, salary_amount, salary_period) VALUES
        (v_r6, 'R6 Mixed', 'mixed', 20, 50, 'monthly');

    INSERT INTO public.flocks (id, farm_id, breed, initial_count, current_count, start_date)
        VALUES (v_fa, v_farmA, 'RPT Flock A', 100, 100, v_pstart),
               (v_fb, v_farmB, 'RPT Flock B', 100, 100, v_pstart);

    -- المزرعة الكاملة: عائد 2400، مصروف 600 -> صافي 1800. القطيع: صافي 300.
    INSERT INTO public.revenue (farm_id, date, category, amount, currency) VALUES
        (v_farmA, v_pend, 'other', 2000, 'dollar');
    INSERT INTO public.expenses (farm_id, date, category, amount, currency) VALUES
        (v_farmA, v_pend, 'other', 500, 'dollar');
    INSERT INTO public.revenue (farm_id, date, category, amount, currency, flock_id) VALUES
        (v_farmA, v_pend, 'other', 400, 'dollar', v_fa);
    INSERT INTO public.expenses (farm_id, date, category, amount, currency, flock_id) VALUES
        (v_farmA, v_pend, 'other', 100, 'dollar', v_fa);

    SELECT count(*) INTO v_cnt FROM public.partners WHERE id IN (v_r1, v_r2, v_r3, v_r4, v_r5, v_r6);
    PERFORM tests.assert('REPORT: تجهيز 6 شركاء', v_cnt = 6, format('n=%s', v_cnt));

    -- ── C) partner_net_profit — كامل المزرعة (NULL قطيع = 1800) ──────────────
    PERFORM tests.assert('REPORT: net R1 نسبة 40% من 1800 = 720',
        public.partner_net_profit(v_r1, v_pstart, v_pend, NULL) = 720, '');
    PERFORM tests.assert('REPORT: net R2 نسبة 60% من 1800 = 1080',
        public.partner_net_profit(v_r2, v_pstart, v_pend, NULL) = 1080, '');
    PERFORM tests.assert('REPORT: net R3 راتب = 300 (مستقل عن الربح)',
        public.partner_net_profit(v_r3, v_pstart, v_pend, NULL) = 300, '');
    PERFORM tests.assert('REPORT: net R4 أسهم 25/120 = 375',
        public.partner_net_profit(v_r4, v_pstart, v_pend, NULL) = 375, '');
    PERFORM tests.assert('REPORT: net R5 أسهم 75/120 = 1125',
        public.partner_net_profit(v_r5, v_pstart, v_pend, NULL) = 1125, '');
    PERFORM tests.assert('REPORT: net R6 مختلط أسهم 20/120 + راتب 50 = 350',
        public.partner_net_profit(v_r6, v_pstart, v_pend, NULL) = 350, '');

    -- ── D) partner_net_profit — على القطيع (net 300) ─────────────────────────
    PERFORM tests.assert('REPORT: net R1 على القطيع = 120',
        public.partner_net_profit(v_r1, v_pstart, v_pend, v_fa) = 120, '');
    PERFORM tests.assert('REPORT: net R4 على القطيع = 62.5',
        public.partner_net_profit(v_r4, v_pstart, v_pend, v_fa) = 62.5, '');
    PERFORM tests.assert('REPORT: net R6 على القطيع = 100 (50 حصة + 50 راتب)',
        public.partner_net_profit(v_r6, v_pstart, v_pend, v_fa) = 100, '');

    -- ── E) فترة فارغة -> صفر ─────────────────────────────────────────────────
    PERFORM tests.assert('REPORT: فترة فارغة تعطي 0',
        public.partner_net_profit(v_r1, DATE '2000-01-01', DATE '2000-01-31', NULL) = 0, '');

    -- ── F) حدود الفترة شاملة، وما خارجها مستبعَد ─────────────────────────────
    INSERT INTO public.revenue (farm_id, date, category, amount, currency)
        VALUES (v_farmA, (v_pstart - INTERVAL '2 years')::date, 'other', 999, 'dollar');
    PERFORM tests.assert('REPORT: عائد خارج الفترة (وسنتين للخلف) مستبعَد من النتيجة',
        public.partner_net_profit(v_r1, v_pstart, v_pend, NULL) = 720, '');
    DELETE FROM public.revenue
     WHERE farm_id = v_farmA AND amount = 999 AND currency = 'dollar';

    -- ── G) calculate_profit_distribution — كامل المزرعة ──────────────────────
    SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL);
    PERFORM tests.assert('REPORT: المعاينة تعيد صفاً لكل شريك نشط (6)', v_cnt = 6, format('n=%s', v_cnt));

    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_r1;
    PERFORM tests.assert('REPORT: معاينة R1 = 720', v_n = 720, format('v=%s', v_n));
    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_r4;
    PERFORM tests.assert('REPORT: معاينة R4 = 375', v_n = 375, format('v=%s', v_n));
    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_r6;
    PERFORM tests.assert('REPORT: معاينة R6 = 350', v_n = 350, format('v=%s', v_n));

    -- ── H) calculate على القطيع ──────────────────────────────────────────────
    SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, v_fa);
    PERFORM tests.assert('REPORT: معاينة القطيع تعيد صفاً لكل شريك (6)', v_cnt = 6, format('n=%s', v_cnt));
    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, v_fa)
     WHERE partner_id = v_r1;
    PERFORM tests.assert('REPORT: معاينة R1 على القطيع = 120', v_n = 120, format('v=%s', v_n));
    SELECT amount INTO v_n FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, v_fa)
     WHERE partner_id = v_r6;
    PERFORM tests.assert('REPORT: معاينة R6 على القطيع = 100', v_n = 100, format('v=%s', v_n));

    -- ── I) الأخطاء ───────────────────────────────────────────────────────────
    UPDATE public.partners SET percentage = 70 WHERE id = v_r2;   -- المجموع 110 > 100
    BEGIN
        SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL);
        PERFORM tests.assert('REPORT: مجموع النسب > 100 مرفوض', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('REPORT: مجموع النسب > 100 مرفوض',
            SQLERRM LIKE '%INVALID_PERCENTAGES%', SQLERRM);
    END;
    UPDATE public.partners SET percentage = 60 WHERE id = v_r2;   -- إعادة إلى 100 بالضبط

    BEGIN
        PERFORM public.partner_net_profit(v_r1, v_pend, v_pstart, NULL);
        PERFORM tests.assert('REPORT: فترة مقلوبة مرفوضة', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('REPORT: فترة مقلوبة مرفوضة', SQLERRM LIKE '%INVALID_PERIOD%', SQLERRM);
    END;

    BEGIN
        SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_ghost, v_pstart, v_pend, NULL);
        PERFORM tests.assert('REPORT: مزرعة غير موجودة مرفوضة', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('REPORT: مزرعة غير موجودة مرفوضة', SQLERRM LIKE '%FARM_NOT_FOUND%', SQLERRM);
    END;

    BEGIN
        SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, v_fb);
        PERFORM tests.assert('REPORT: قطيع مزرعة أخرى مرفوض', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('REPORT: قطيع مزرعة أخرى مرفوض', SQLERRM LIKE '%FLOCK_FARM_MISMATCH%', SQLERRM);
    END;

    -- ── J) partner_summary — النماذج الأربعة + تدفقات السحب ──────────────────
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by, status)
        VALUES (v_wp, v_r1, v_farmA, 30, v_sys, 'pending');
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by, status, paid_at)
        VALUES (v_wd, v_r1, v_farmA, 50, v_sys, 'paid', now());

    SELECT * INTO v_row FROM public.partner_summary(v_r1);
    PERFORM tests.assert('REPORT: ملخص R1 — النموذج نسبة 40', v_row.share_model = 'percentage' AND v_row.share_value = 40,
        format('m=%s v=%s', v_row.share_model, v_row.share_value));
    PERFORM tests.assert('REPORT: ملخص R1 — الصافي 720', v_row.net_profit = 720, format('net=%s', v_row.net_profit));
    PERFORM tests.assert('REPORT: ملخص R1 — معلّق 30', v_row.pending = 30, format('p=%s', v_row.pending));
    PERFORM tests.assert('REPORT: ملخص R1 — مدفوع 50', v_row.paid = 50, format('paid=%s', v_row.paid));

    SELECT * INTO v_row FROM public.partner_summary(v_r3);
    PERFORM tests.assert('REPORT: ملخص R3 — قيمة الراتب 300', v_row.share_model = 'salary' AND v_row.share_value = 300,
        format('v=%s', v_row.share_value));

    SELECT * INTO v_row FROM public.partner_summary(v_r4);
    PERFORM tests.assert('REPORT: ملخص R4 — قيمة الأسهم 25', v_row.share_model = 'shares' AND v_row.share_value = 25,
        format('v=%s', v_row.share_value));

    SELECT * INTO v_row FROM public.partner_summary(v_r6);
    PERFORM tests.assert('REPORT: ملخص R6 — المختلط يعرض الأسهم 20', v_row.share_model = 'mixed' AND v_row.share_value = 20,
        format('v=%s', v_row.share_value));

    -- المدير-الشريك يقرأ ملخص نفسه (R1 user = admin)
    PERFORM tests.set_user(v_admin);
    SELECT * INTO v_row FROM public.partner_summary(v_r1);
    PERFORM tests.assert('REPORT: المدير-الشريك يقرأ ملخص نفسه', v_row.net_profit = 720, format('net=%s', v_row.net_profit));

    -- ── K) M29-v2: العملات المختلطة مسموحة (amount = USD دائمًا، currency وصفية)
    -- لا يُرفع MIXED_CURRENCY؛ إيراد +5 يرفع صافي R1 (40%) بمقدار 2.
    PERFORM tests.set_user(v_sys);
    v_n := public.partner_net_profit(v_r1, v_pstart, v_pend, NULL);
    INSERT INTO public.revenue (farm_id, date, category, amount, currency)
        VALUES (v_farmA, v_pend, 'other', 5, 'lira');
    BEGIN
        SELECT count(*) INTO v_cnt FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL);
        PERFORM tests.assert('REPORT: عملات مختلطة مسموحة (توزيع)', v_cnt > 0, format('n=%s', v_cnt));
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('REPORT: عملات مختلطة مسموحة (توزيع)', false, SQLERRM);
    END;
    BEGIN
        PERFORM tests.assert('REPORT: عملات مختلطة مسموحة (صافي) = السابق + 2',
            public.partner_net_profit(v_r1, v_pstart, v_pend, NULL) = v_n + 2, format('n=%s', v_n));
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('REPORT: عملات مختلطة مسموحة (صافي) = السابق + 2', false, SQLERRM);
    END;
    DELETE FROM public.revenue
     WHERE farm_id = v_farmA AND currency = 'lira' AND date = v_pend;
    PERFORM tests.assert('REPORT: بعد إزالة العملة الثانية يعود الصافي 720',
        public.partner_net_profit(v_r1, v_pstart, v_pend, NULL) = 720, '');

    RAISE NOTICE 'p0_partner_reports: انتهى — النماذج الأربعة والحدود والأخطاء';
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_partner_reports: كل الفحوص PASS — التقارير دقيقة والحدود مضبوطة';
END; $final$;

ROLLBACK;
