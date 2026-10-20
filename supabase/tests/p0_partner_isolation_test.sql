-- ============================================================================
--  p0_partner_isolation_test.sql
--  W6-M27: cross-farm / cross-partner isolation on the six partnership tables
--  تتحقق من أن مدير مزرعة لا يرى ولا يكتب صفوف مزرعة أخرى، وأن الشريك لا يرى
--  إلا صفّه، ومن أن مفاتيح FK المركّبة ترفض ربط بند/سحب بمزرعةٍ لا تخصّ التوزيع.
--  تعمل كـtest_runner (بلا BYPASSRLS) داخل BEGIN ... ROLLBACK.
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

    v_pa uuid := '11111111-0000-0000-0000-0000000000a1';  -- user = admin A
    v_pb uuid := '11111111-0000-0000-0000-0000000000b1';  -- user = admin B
    v_pw uuid := '11111111-0000-0000-0000-0000000000c1';  -- user = worker A, no business

    v_da uuid := '22222222-0000-0000-0000-0000000000a1';
    v_db uuid := '22222222-0000-0000-0000-0000000000b1';
    v_ddpa uuid := '66666666-0000-0000-0000-0000000000a1';
    v_ddpb uuid := '66666666-0000-0000-0000-0000000000b1';
    v_wa uuid := '33333333-0000-0000-0000-0000000000a1';
    v_wb uuid := '33333333-0000-0000-0000-0000000000b1';

    v_n int;
    v_row record;
BEGIN
    -- ── A) البنية: RLS + العدّ + الدالة المساعدة + المنح ─────────────────────
    PERFORM tests.assert('ISO: RLS مفعّل على الجداول الستة',
        (SELECT bool_and(c.relrowsecurity) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='public' AND c.relname IN ('partners','user_roles','profit_distributions',
              'profit_distribution_details','partner_withdrawals','partner_audit')), '');

    SELECT count(*) INTO v_n FROM pg_policies
     WHERE schemaname='public' AND tablename IN ('partners','user_roles','profit_distributions',
           'profit_distribution_details','partner_withdrawals','partner_audit');
    PERFORM tests.assert('ISO: مجموع السياسات = 24 (4/4/4/4/5/3)', v_n = 24, format('n=%s', v_n));

    PERFORM tests.assert('ISO: partner_audit بلا سياسة كتابة (append-only)',
        NOT EXISTS (SELECT 1 FROM pg_policies
                     WHERE schemaname='public' AND tablename='partner_audit' AND cmd <> 'SELECT'), '');

    PERFORM tests.assert('ISO: الدالة المساعدة SECURITY DEFINER وauthenticated ينفّذها وبلا PUBLIC',
        (SELECT prosecdef FROM pg_proc WHERE proname='partner_in_manager_farm')
        AND has_function_privilege('authenticated','public.partner_in_manager_farm(uuid)','EXECUTE')
        AND NOT EXISTS (SELECT 1 FROM pg_proc pr
                        CROSS JOIN LATERAL aclexplode(COALESCE(pr.proacl, acldefault('f', pr.proowner))) a
                         WHERE pr.proname='partner_in_manager_farm' AND a.grantee=0 AND a.privilege_type='EXECUTE'), '');

    PERFORM tests.assert('ISO: anon بلا وصول لأي جدول',
        NOT has_table_privilege('anon','public.partners','SELECT')
        AND NOT has_table_privilege('anon','public.partner_withdrawals','SELECT'), '');

    -- ── B) التجهيز كـsystem_admin ────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);

    INSERT INTO public.partners (id, user_id, name, share_model, percentage) VALUES
        (v_pa, v_admin,  'ISO Partner A', 'percentage', 50),
        (v_pb, v_adminB, 'ISO Partner B', 'percentage', 50),
        (v_pw, v_worker, 'ISO Partner W', 'percentage', 50);

    INSERT INTO public.profit_distributions (id, farm_id, period_start, period_end) VALUES
        (v_da, v_farmA, DATE '2026-03-01', DATE '2026-03-31'),
        (v_db, v_farmB, DATE '2026-03-01', DATE '2026-03-31');

    INSERT INTO public.profit_distribution_details (id, distribution_id, farm_id, partner_id, share_model, percentage, profit_share, net_amount)
        VALUES (v_ddpa, v_da, v_farmA, v_pa, 'percentage', 50, 10, 10),
               (v_ddpb, v_db, v_farmB, v_pb, 'percentage', 50, 10, 10);

    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by, status)
        VALUES (v_wa, v_pa, v_farmA, 10, v_sys, 'pending'),
               (v_wb, v_pb, v_farmB, 10, v_sys, 'pending');

    INSERT INTO public.user_roles (user_id, farm_id, role) VALUES
        (v_admin,  v_farmA, 'manager'),
        (v_adminB, v_farmB, 'manager');

    PERFORM public.record_partner_audit(v_farmA, 'added', v_sys, v_pa);
    PERFORM public.record_partner_audit(v_farmB, 'added', v_sys, v_pb);
    PERFORM tests.assert('ISO: التجهيز نجح', true, '');

    -- ── C) system_admin يرى كل شيء ───────────────────────────────────────────
    SELECT count(*) INTO v_n FROM public.partners;
    PERFORM tests.assert('ISO: admin يرى 3 شركاء', v_n = 3, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.profit_distributions;
    PERFORM tests.assert('ISO: admin يرى التوزيعين', v_n = 2, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.profit_distribution_details;
    PERFORM tests.assert('ISO: admin يرى البندين', v_n = 2, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partner_withdrawals;
    PERFORM tests.assert('ISO: admin يرى السحبين', v_n = 2, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partner_audit;
    -- W7.4: محفّز السحب يضيف سطرين تلقائيين (طلبَي wa/wb) إلى السطرين اليدويين.
    PERFORM tests.assert('ISO: admin يرى كل التدقيق (2 يدوي + 2 محفّز)', v_n = 4, format('n=%s', v_n));

    -- ── D) عزل مزرعة المدير A ────────────────────────────────────────────────
    PERFORM tests.set_user(v_admin);
    SELECT count(*) INTO v_n FROM public.partners;
    PERFORM tests.assert('ISO: مدير A يرى شريك مزرعته فقط (1)', v_n = 1, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partners WHERE id = v_pb;
    PERFORM tests.assert('ISO: مدير A لا يرى شريك مزرعة B', v_n = 0, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partners WHERE id = v_pw;
    PERFORM tests.assert('ISO: مدير A لا يرى شريكاً بلا أعمال في مزرعته', v_n = 0, format('n=%s', v_n));

    SELECT count(*) INTO v_n FROM public.profit_distributions;
    PERFORM tests.assert('ISO: مدير A يرى توزيع مزرعته فقط (1)', v_n = 1, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.profit_distributions WHERE farm_id = v_farmB;
    PERFORM tests.assert('ISO: مدير A لا يرى توزيع مزرعة B', v_n = 0, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.profit_distribution_details;
    PERFORM tests.assert('ISO: مدير A يرى بند مزرعته فقط (1)', v_n = 1, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partner_withdrawals;
    PERFORM tests.assert('ISO: مدير A يرى سحب مزرعته فقط (1)', v_n = 1, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partner_audit;
    -- W7.4: مزرعة A ترى اليدوي (added pa) + تلقائي (طلب wa).
    PERFORM tests.assert('ISO: مدير A يرى تدقيق مزرعته فقط (2)', v_n = 2, format('n=%s', v_n));

    -- ── E) عزل مزرعة المدير B ────────────────────────────────────────────────
    PERFORM tests.set_user(v_adminB);
    SELECT count(*) INTO v_n FROM public.partners;
    PERFORM tests.assert('ISO: مدير B يرى شريك مزرعته فقط (1)', v_n = 1, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.profit_distributions WHERE farm_id = v_farmA;
    PERFORM tests.assert('ISO: مدير B لا يرى توزيع مزرعة A', v_n = 0, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.profit_distribution_details WHERE farm_id = v_farmA;
    PERFORM tests.assert('ISO: مدير B لا يرى بنود مزرعة A', v_n = 0, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partner_withdrawals WHERE farm_id = v_farmA;
    PERFORM tests.assert('ISO: مدير B لا يرى سحوبات مزرعة A', v_n = 0, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partner_audit WHERE farm_id = v_farmA;
    PERFORM tests.assert('ISO: مدير B لا يرى تدقيق مزرعة A', v_n = 0, format('n=%s', v_n));

    -- ── F) عزل الشريك عن نفسه (العامل-الشريك W) ──────────────────────────────
    PERFORM tests.set_user(v_worker);
    SELECT count(*) INTO v_n FROM public.partners;
    PERFORM tests.assert('ISO: العامل-الشريك يرى صفّه فقط (1)', v_n = 1, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partners WHERE id = v_pa;
    PERFORM tests.assert('ISO: العامل-الشريك لا يرى شريكاً آخر', v_n = 0, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.profit_distribution_details;
    PERFORM tests.assert('ISO: العامل-الشريك بلا بنود (0)', v_n = 0, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.profit_distributions;
    PERFORM tests.assert('ISO: العامل-الشريك بلا توزيعات (0)', v_n = 0, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partner_withdrawals;
    PERFORM tests.assert('ISO: العامل-الشريك بلا سحوبات (0)', v_n = 0, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partner_audit;
    PERFORM tests.assert('ISO: العامل-الشريك بلا تدقيق (0)', v_n = 0, format('n=%s', v_n));

    -- ── G) عزل الكتابة للمدير A ──────────────────────────────────────────────
    PERFORM tests.set_user(v_admin);
    UPDATE public.partners SET phone = '0700' WHERE id = v_pb;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM tests.assert('ISO: مدير A لا يعدّل شريك مزرعة B', v_n = 0, format('n=%s', v_n));
    UPDATE public.partners SET phone = '0701' WHERE id = v_pw;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM tests.assert('ISO: مدير A لا يعدّل شريكاً بلا أعمال في مزرعته', v_n = 0, format('n=%s', v_n));

    UPDATE public.partner_withdrawals SET status = 'approved', reviewed_by = v_admin WHERE id = v_wb;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM tests.assert('ISO: مدير A لا يعدّل سحب مزرعة B', v_n = 0, format('n=%s', v_n));

    UPDATE public.profit_distributions SET label = 'x' WHERE id = v_db;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM tests.assert('ISO: مدير A لا يعدّل توزيع مزرعة B', v_n = 0, format('n=%s', v_n));

    BEGIN
        INSERT INTO public.user_roles (user_id, farm_id, role) VALUES (v_worker, v_farmB, 'supervisor');
        PERFORM tests.assert('ISO: مدير A لا يمنح دوراً على مزرعة أخرى', false, 'نجح الإدخال');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('ISO: مدير A لا يمنح دوراً على مزرعة أخرى', true, SQLERRM);
    END;

    -- ── H) عزل على مستوى الدوال ─────────────────────────────────────────────
    SELECT * INTO v_row FROM public.partner_summary(v_pa);
    PERFORM tests.assert('ISO: مدير A يقرأ ملخص شريكه (نفسه)', v_row.share_value = 50, '');

    BEGIN
        PERFORM public.partner_summary(v_pb);
        PERFORM tests.assert('ISO: مدير A لا يقرأ ملخص شريك مزرعة B', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('ISO: مدير A لا يقرأ ملخص شريك مزرعة B', SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    BEGIN
        PERFORM public.partner_net_profit(v_pb, DATE '2026-03-01', DATE '2026-03-31', NULL);
        PERFORM tests.assert('ISO: مدير A لا يحسب صافي شريك مزرعة B', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('ISO: مدير A لا يحسب صافي شريك مزرعة B', SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    PERFORM tests.set_user(v_adminB);
    BEGIN
        PERFORM public.partner_net_profit(v_pa, DATE '2026-03-01', DATE '2026-03-31', NULL);
        PERFORM tests.assert('ISO: مدير B لا يحسب صافي شريك مزرعة A', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('ISO: مدير B لا يحسب صافي شريك مزرعة A', SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;
    BEGIN
        SELECT count(*) INTO v_n FROM public.calculate_profit_distribution(v_farmA, DATE '2026-03-01', DATE '2026-03-31', NULL);
        PERFORM tests.assert('ISO: مدير B لا يحسب توزيع مزرعة A', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('ISO: مدير B لا يحسب توزيع مزرعة A', SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    PERFORM tests.set_user(v_worker);
    BEGIN
        PERFORM public.approve_withdrawal(v_wa, v_worker);
        PERFORM tests.assert('ISO: العامل لا يعتمد سحباً', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('ISO: العامل لا يعتمد سحباً', SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    PERFORM tests.set_user(v_adminB);
    BEGIN
        PERFORM public.approve_withdrawal(v_wa, v_adminB);
        PERFORM tests.assert('ISO: مدير B لا يعتمد سحب مزرعة A', false, 'مرّ');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('ISO: مدير B لا يعتمد سحب مزرعة A', SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    PERFORM tests.set_user(v_admin);
    PERFORM public.approve_withdrawal(v_wa, v_admin);
    PERFORM tests.assert('ISO: مدير A يعتمد سحب مزرعته',
        (SELECT status = 'approved' FROM public.partner_withdrawals WHERE id = v_wa), '');

    -- ── I) العامل-الشريك ينشئ لنفسه فقط ─────────────────────────────────────
    -- (يُجرى بعد فحوص كتابة المدير، لأن إنشاء سحبٍ له يجعل PW "له أعمال" في
    --  مزرعة A فيصبح مرئياً للمدير A، وهو سلوك مقصود في نموذج M25).
    PERFORM tests.set_user(v_worker);
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES ('33333333-0000-0000-0000-0000000000c9', v_pw, v_farmA, 5, v_worker);
    PERFORM tests.assert('ISO: العامل-الشريك ينشئ سحباً لنفسه', true, '');
    BEGIN
        INSERT INTO public.partner_withdrawals (partner_id, farm_id, amount, requested_by)
            VALUES (v_pa, v_farmA, 5, v_worker);
        PERFORM tests.assert('ISO: العامل-الشريك لا ينشئ سحباً لشريك آخر', false, 'نجح الإدخال');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('ISO: العامل-الشريك لا ينشئ سحباً لشريك آخر', true, SQLERRM);
    END;

    -- ── J) رفض FK المركّب عند اختلاف المزرعة (كـsystem_admin) ────────────────
    PERFORM tests.set_user(v_sys);
    BEGIN
        INSERT INTO public.profit_distribution_details
            (distribution_id, farm_id, partner_id, share_model, percentage)
            VALUES (v_da, v_farmB, v_pw, 'percentage', 50);
        PERFORM tests.assert('ISO: بند توزيع بمزرعة مختلفة مرفوض (FK مركّب)', false, 'نجح الإدخال');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('ISO: بند توزيع بمزرعة مختلفة مرفوض (FK مركّب)', true, SQLERRM);
    END;

    BEGIN
        INSERT INTO public.partner_withdrawals
            (partner_id, farm_id, distribution_id, amount, requested_by)
            VALUES (v_pa, v_farmB, v_da, 10, v_sys);
        PERFORM tests.assert('ISO: سحب بتوزيع مزرعة مختلفة مرفوض', false, 'نجح الإدخال');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('ISO: سحب بتوزيع مزرعة مختلفة مرفوض',
            SQLERRM LIKE '%WITHDRAWAL_DISTRIBUTION_MISMATCH%', SQLERRM);
    END;

    RAISE NOTICE 'p0_partner_isolation: انتهى — عزل cross-farm/cross-partner وFK مركّب';
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_partner_isolation: كل الفحوص PASS — لا تسريب بين المزارع ولا بين الشركاء';
END; $final$;

ROLLBACK;
