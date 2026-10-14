-- ============================================================================
--  p0_partner_net_profit_fix_v2_test.sql
--  خطة W6-M29-v2: إزالة MIXED_CURRENCY من دوال ربح الشريك
--  --------------------------------------------------------------------------
--  القاعدة: amount = USD دائمًا. currency = بيانات وصفية (كيف دُفعت).
--  exchange_rate = سعر الصرف لحظة الإدخال ولا يُقرأ هنا.
--  لذلك اختلاف currency بين صفوف revenue أو expenses ليس تعارضًا، ولا يجوز
--  رفع MIXED_CURRENCY. هذا الاختبار يُدخل مصاريف وإيرادات بعملتين (dollar +
--  lira) ويتأكد أن الدالتين ترجعان المجموع الصحيح بلا استثناء.
--
--  الاختبار يعمل كـtest_runner (بدون BYPASSRLS) عبر run_all.py، وكل شيء داخل
--  BEGIN ... ROLLBACK فلا يمسّ بيانات دائمة.
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

    v_pa  uuid := '11111111-0000-0000-0000-0000000000a1';  -- 50%
    v_pb  uuid := '11111111-0000-0000-0000-0000000000b1';  -- 40%
    v_pc  uuid := '11111111-0000-0000-0000-0000000000c1';  -- salary 200

    v_fl1 uuid := '55555555-0000-0000-0000-000000000001';
    v_fl2 uuid := '55555555-0000-0000-0000-000000000002';

    v_cust1 uuid := '66666666-0000-0000-0000-000000000001';
    v_cust2 uuid := '66666666-0000-0000-0000-000000000002';

    v_disp1 uuid := '77777777-0000-0000-0000-000000000001';  -- fl1
    v_disp2 uuid := '77777777-0000-0000-0000-000000000002';  -- fl2

    v_pay1 uuid := '88888888-0000-0000-0000-000000000001';  -- disp1 lira 250
    v_pay2 uuid := '88888888-0000-0000-0000-000000000002';  -- disp1 dollar 150
    v_pay3 uuid := '88888888-0000-0000-0000-000000000003';  -- disp2 dollar 200
    v_pay4 uuid := '88888888-0000-0000-0000-000000000004';  -- no dispatch 500
    v_pay5 uuid := '88888888-0000-0000-0000-000000000005';  -- soft-deleted 999

    v_pstart date := date_trunc('month', CURRENT_DATE)::date;
    v_pend   date := CURRENT_DATE;

    v_n    numeric;
    v_amt  numeric;
    v_txt  text;
    v_type text;
    v_cnt  integer;
BEGIN
    -- ── A) البنية والصلاحيات ────────────────────────────────────────────────
    PERFORM tests.assert('M29v2: الدالتان المطلوبتان موجودتان بنفس التوقيع',
        to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)') IS NOT NULL
        AND to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)') IS NOT NULL, '');

    PERFORM tests.assert('M29v2: كلتاهما SECURITY DEFINER',
        (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'))
        AND (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)')), '');

    PERFORM tests.assert('M29v2: search_path مثبّت على كلتيهما',
        (SELECT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%')
           FROM pg_proc p WHERE p.oid = to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'))
        AND (SELECT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%')
               FROM pg_proc p WHERE p.oid = to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)')), '');

    v_txt := pg_get_functiondef(to_regprocedure('public.partner_net_profit(uuid,date,date,uuid)'));
    PERFORM tests.assert('M29v2: partner_net_profit يقرأ payments.amount_paid (أساس M29 باقٍ)',
        position('payments' IN v_txt) > 0 AND position('amount_paid' IN v_txt) > 0, '');
    PERFORM tests.assert('M29v2: partner_net_profit لا يحتوي MIXED_CURRENCY',
        position('MIXED_CURRENCY' IN v_txt) = 0, '');
    PERFORM tests.assert('M29v2: partner_net_profit لا يقرأ exchange_rate (كل شيء USD)',
        position('exchange_rate' IN v_txt) = 0, '');

    v_txt := pg_get_functiondef(to_regprocedure('public.calculate_profit_distribution(uuid,date,date,uuid)'));
    PERFORM tests.assert('M29v2: calculate_profit_distribution يقرأ payments.amount_paid (أساس M29 باقٍ)',
        position('payments' IN v_txt) > 0 AND position('amount_paid' IN v_txt) > 0, '');
    PERFORM tests.assert('M29v2: calculate_profit_distribution لا يحتوي MIXED_CURRENCY',
        position('MIXED_CURRENCY' IN v_txt) = 0, '');
    PERFORM tests.assert('M29v2: calculate_profit_distribution لا يقرأ exchange_rate',
        position('exchange_rate' IN v_txt) = 0, '');

    PERFORM tests.assert('M29v2: anon لا ينفّذ أي دالة، authenticated ينفّذ',
        NOT has_function_privilege('anon', 'public.partner_net_profit(uuid,date,date,uuid)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'public.calculate_profit_distribution(uuid,date,date,uuid)', 'EXECUTE')
        AND has_function_privilege('authenticated', 'public.partner_net_profit(uuid,date,date,uuid)', 'EXECUTE')
        AND has_function_privilege('authenticated', 'public.calculate_profit_distribution(uuid,date,date,uuid)', 'EXECUTE'), '');

    -- ── B) التجهيز كـsystem_admin ────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);

    INSERT INTO public.partners (id, user_id, name, share_model, percentage) VALUES
        (v_pa, v_admin, 'M29v2 A 50', 'percentage', 50),
        (v_pb, NULL,    'M29v2 B 40', 'percentage', 40);
    INSERT INTO public.partners (id, name, share_model, salary_amount, salary_period)
        VALUES (v_pc, 'M29v2 C salary', 'salary', 200, 'monthly');

    INSERT INTO public.flocks (id, farm_id, breed, initial_count, current_count, start_date)
        VALUES (v_fl1, v_farmA, 'M29v2 FL1', 100, 100, v_pstart),
               (v_fl2, v_farmA, 'M29v2 FL2', 100, 100, v_pstart);

    INSERT INTO public.customers (id, farm_id, name, phone)
        VALUES (v_cust1, v_farmA, 'M29v2 C1', '0500000001'),
               (v_cust2, v_farmA, 'M29v2 C2', '0500000002');

    INSERT INTO public.egg_dispatch (id, farm_id, flock_id, date, customer_id,
                                     cartons, trays, total_eggs, payment_status, worker_id)
        VALUES (v_disp1, v_farmA, v_fl1, v_pend, v_cust1, 1, 0, 30, 'paid', v_worker),
               (v_disp2, v_farmA, v_fl2, v_pend, v_cust2, 1, 0, 30, 'paid', v_worker);

    -- الإيراد: 1000 (dollar) + 300 (lira!) لقطيع1 + 200 (dollar) لقطيع2 = 1500
    -- العملتان تختلفان → M29 كان سيرفع MIXED_CURRENCY، M29-v2 لا.
    INSERT INTO public.revenue (farm_id, date, category, amount, currency, flock_id) VALUES
        (v_farmA, v_pend, 'other',    1000, 'dollar', NULL),
        (v_farmA, v_pend, 'eggSales',  300, 'lira',   v_fl1),
        (v_farmA, v_pend, 'eggSales',  200, 'dollar', v_fl2);

    -- المصاريف: 400 (dollar) + 100 (dollar) + 50 (lira!) = 550
    -- العملتان تختلفان → M29 كان سيرفع MIXED_CURRENCY، M29-v2 لا.
    INSERT INTO public.expenses (farm_id, date, category, amount, currency, flock_id) VALUES
        (v_farmA, v_pend, 'other', 400, 'dollar', NULL),
        (v_farmA, v_pend, 'feed',  100, 'dollar', v_fl1),
        (v_farmA, v_pend, 'feed',   50, 'lira',   v_fl2);

    -- الدفعات: 250 (lira، سعر صرف 15000 لا يُقرأ) + 150 + 200 + 500 مباشر = 1100
    -- والمحذوفة 999 مستثناة.
    INSERT INTO public.payments (id, farm_id, dispatch_id, customer_id, date, price_per_carton,
                                 total_due, amount_paid, payment_method, currency, exchange_rate, manager_id)
        VALUES (v_pay1, v_farmA, v_disp1, v_cust1, v_pend, 250, 250, 250, 'cash', 'lira',   15000, v_admin),
               (v_pay2, v_farmA, v_disp1, v_cust1, v_pend, 150, 150, 150, 'cash', 'dollar', NULL,  v_admin),
               (v_pay3, v_farmA, v_disp2, v_cust2, v_pend, 200, 200, 200, 'cash', 'dollar', NULL,  v_admin),
               (v_pay4, v_farmA, NULL,    v_cust1, v_pend, 500, 500, 500, 'cash', 'dollar', NULL,  v_admin);
    INSERT INTO public.payments (id, farm_id, dispatch_id, customer_id, date, price_per_carton,
                                 total_due, amount_paid, payment_method, currency, manager_id, deleted_at)
        VALUES (v_pay5, v_farmA, NULL, v_cust1, v_pend, 999, 999, 999, 'cash', 'dollar', v_admin, now());

    -- ── C) سلامة التجهيز + إثبات تعدّد العملات ──────────────────────────────
    SELECT COALESCE(SUM(amount_paid), 0) INTO v_n
      FROM public.payments
     WHERE farm_id = v_farmA AND deleted_at IS NULL
       AND date BETWEEN v_pstart AND v_pend;
    PERFORM tests.assert('M29v2: مجموع payments الحيّة في الفترة = 1100', v_n = 1100, format('pay=%s', v_n));

    SELECT COALESCE(SUM(amount), 0) INTO v_n
      FROM public.revenue
     WHERE farm_id = v_farmA AND deleted_at IS NULL
       AND date BETWEEN v_pstart AND v_pend;
    PERFORM tests.assert('M29v2: مجموع revenue في الفترة = 1500', v_n = 1500, format('rev=%s', v_n));

    SELECT COUNT(DISTINCT currency) INTO v_cnt
      FROM public.revenue
     WHERE farm_id = v_farmA AND deleted_at IS NULL
       AND date BETWEEN v_pstart AND v_pend;
    PERFORM tests.assert('M29v2: revenue يمتدّ على عملتين (dollar+lira)', v_cnt = 2, format('cur=%s', v_cnt));

    SELECT COALESCE(SUM(amount), 0) INTO v_n
      FROM public.expenses
     WHERE farm_id = v_farmA AND deleted_at IS NULL
       AND date BETWEEN v_pstart AND v_pend;
    PERFORM tests.assert('M29v2: مجموع expenses في الفترة = 550', v_n = 550, format('exp=%s', v_n));

    SELECT COUNT(DISTINCT currency) INTO v_cnt
      FROM public.expenses
     WHERE farm_id = v_farmA AND deleted_at IS NULL
       AND date BETWEEN v_pstart AND v_pend;
    PERFORM tests.assert('M29v2: expenses يمتدّ على عملتين (dollar+lira)', v_cnt = 2, format('cur=%s', v_cnt));

    -- ── D) partner_net_profit — القيم ───────────────────────────────────────
    -- net(المزرعة) = (1500 + 1100) − 550 = 2050  →  A 50% = 1025
    v_n := public.partner_net_profit(v_pa, v_pstart, v_pend, NULL);
    PERFORM tests.assert('M29v2: صافي A الكامل = (1500+1100−550)×50% = 1025',
        v_n = 1025, format('n=%s', v_n));

    PERFORM tests.assert('M29v2: الأساس ضمّ payments (M24 كان سيعطي 475 فقط)',
        public.partner_net_profit(v_pa, v_pstart, v_pend, NULL) = 1025
        AND public.partner_net_profit(v_pa, v_pstart, v_pend, NULL) <> 475, '');

    -- قطيع1: (300 + 400 − 100) = 600 → A 50% = 300
    v_n := public.partner_net_profit(v_pa, v_pstart, v_pend, v_fl1);
    PERFORM tests.assert('M29v2: صافي A على قطيع1 = (300+400−100)×50% = 300',
        v_n = 300, format('n=%s', v_n));

    -- قطيع2: (200 + 200 − 50) = 350 → A 50% = 175
    v_n := public.partner_net_profit(v_pa, v_pstart, v_pend, v_fl2);
    PERFORM tests.assert('M29v2: صافي A على قطيع2 = (200+200−50)×50% = 175',
        v_n = 175, format('n=%s', v_n));

    v_n := public.partner_net_profit(v_pb, v_pstart, v_pend, NULL);
    PERFORM tests.assert('M29v2: صافي B الكامل = 2050×40% = 820', v_n = 820, format('n=%s', v_n));

    v_n := public.partner_net_profit(v_pc, v_pstart, v_pend, NULL);
    PERFORM tests.assert('M29v2: صافي C (راتب) = 200 لا يتأثر بالصافي',
        v_n = 200, format('n=%s', v_n));

    v_n := public.partner_net_profit(v_pa, CURRENT_DATE - 30, CURRENT_DATE - 20, NULL);
    PERFORM tests.assert('M29v2: فترة بلا بيانات = 0', v_n = 0, format('n=%s', v_n));

    -- ── E) تعدّد العملات لا يرفع MIXED_CURRENCY (جوهر M29-v2) ────────────────
    BEGIN
        v_n := public.partner_net_profit(v_pa, v_pstart, v_pend, NULL);
        PERFORM tests.assert('M29v2: عملات revenue/expenses المختلفة لا ترفع MIXED_CURRENCY (net=1025)',
            v_n = 1025, format('n=%s', v_n));
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M29v2: عملات revenue/expenses المختلفة لا ترفع MIXED_CURRENCY (net=1025)',
            false, SQLERRM);
    END;

    BEGIN
        SELECT amount INTO v_amt
          FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
         WHERE partner_id = v_pa;
        PERFORM tests.assert('M29v2: calculate لا يرفع MIXED_CURRENCY مع عملات مختلطة (A=1025)',
            v_amt = 1025, format('a=%s', v_amt));
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M29v2: calculate لا يرفع MIXED_CURRENCY مع عملات مختلطة (A=1025)',
            false, SQLERRM);
    END;

    -- ── F) calculate_profit_distribution — المعاينة ─────────────────────────
    SELECT amount INTO v_amt
      FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_pa;
    PERFORM tests.assert('M29v2: توزيع A الكامل = 1025', v_amt = 1025, format('a=%s', v_amt));

    SELECT amount INTO v_amt
      FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_pb;
    PERFORM tests.assert('M29v2: توزيع B الكامل = 820', v_amt = 820, format('a=%s', v_amt));

    SELECT amount INTO v_amt
      FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_pc;
    PERFORM tests.assert('M29v2: توزيع C (راتب) = 200', v_amt = 200, format('a=%s', v_amt));

    SELECT share_type INTO v_type
      FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, NULL)
     WHERE partner_id = v_pa;
    PERFORM tests.assert('M29v2: نوع حصة A = percentage', v_type = 'percentage', format('t=%s', v_type));

    -- قطيع1: 600×50% = 300
    SELECT amount INTO v_amt
      FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, v_fl1)
     WHERE partner_id = v_pa;
    PERFORM tests.assert('M29v2: توزيع A على قطيع1 = 300', v_amt = 300, format('a=%s', v_amt));

    -- قطيع2: 350×50% = 175
    SELECT amount INTO v_amt
      FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, v_fl2)
     WHERE partner_id = v_pa;
    PERFORM tests.assert('M29v2: توزيع A على قطيع2 = 175', v_amt = 175, format('a=%s', v_amt));

    -- الدفعة المباشرة (بلا dispatch) تدخل الفترة الكاملة وتُستثنى من نطاق القطيع:
    -- لو دخلت، لكان توزيع قطيع1 = (300+400+500−100)×50% = 550.
    PERFORM tests.assert('M29v2: دفعة بلا dispatch تُستثنى من نطاق القطيع',
        (SELECT amount FROM public.calculate_profit_distribution(v_farmA, v_pstart, v_pend, v_fl1)
          WHERE partner_id = v_pa) = 300, '');

    -- ── G) partner_summary يعكس الأساس الجديد ───────────────────────────────
    SELECT net_profit INTO v_n FROM public.partner_summary(v_pa);
    PERFORM tests.assert('M29v2: ملخص A (YTD) = 1025', v_n = 1025, format('net=%s', v_n));
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_partner_net_profit_fix_v2: انتهى — currency بيانات وصفية، لا MIXED_CURRENCY';
END; $final$;

ROLLBACK;
