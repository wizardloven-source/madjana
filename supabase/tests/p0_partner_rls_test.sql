-- ============================================================================
--  p0_partner_rls_test.sql
--  W6-M25: advanced RLS on the six partnership tables
--  تُشغَّل كـtest_runner (ليس superuser ولا BYPASSRLS) حتى تكون فحوص RLS حقيقية.
--  تعمل داخل BEGIN ... ROLLBACK فلا تترك أثراً.
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
    v_pd uuid := '11111111-0000-0000-0000-0000000000d1';

    v_da uuid := '22222222-0000-0000-0000-0000000000a1';
    v_db uuid := '22222222-0000-0000-0000-0000000000b1';

    v_ddpa uuid := '66666666-0000-0000-0000-0000000000a1';
    v_ddpc uuid := '66666666-0000-0000-0000-0000000000a2';
    v_ddpd uuid := '66666666-0000-0000-0000-0000000000b1';

    v_wpa uuid := '33333333-0000-0000-0000-0000000000a1';
    v_wpc uuid := '33333333-0000-0000-0000-0000000000a2';
    v_wpd uuid := '33333333-0000-0000-0000-0000000000b1';

    v_n int;
BEGIN
    -- ── A) البنية: السياسات + RLS + الدالة المساعدة ─────────────────────────
    PERFORM tests.assert('M25: RLS مفعّل على الجداول الستة',
        (SELECT bool_and(c.relrowsecurity) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='public' AND c.relname IN ('partners','user_roles','profit_distributions',
              'profit_distribution_details','partner_withdrawals','partner_audit')), '');

    PERFORM tests.assert('M25: partners = 4 سياسات',
        (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='partners') = 4, '');
    PERFORM tests.assert('M25: user_roles = 4 سياسات',
        (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='user_roles') = 4, '');
    PERFORM tests.assert('M25: profit_distributions = 4 سياسات',
        (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='profit_distributions') = 4, '');
    PERFORM tests.assert('M25: profit_distribution_details = 4 سياسات',
        (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='profit_distribution_details') = 4, '');
    PERFORM tests.assert('M25: partner_withdrawals = 5 سياسات',
        (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='partner_withdrawals') = 5, '');
    PERFORM tests.assert('M25: partner_audit = 3 سياسات',
        (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='partner_audit') = 3, '');

    PERFORM tests.assert('M25: كل جدول له سياسة is_system_admin',
        (SELECT count(*) FROM (VALUES ('partners'),('user_roles'),('profit_distributions'),
             ('profit_distribution_details'),('partner_withdrawals'),('partner_audit')) t(tbl)
          WHERE EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname='public'
                          AND p.tablename=t.tbl AND p.qual LIKE '%is_system_admin%')) = 6, '');

    PERFORM tests.assert('M25: partner_audit يبقى للقراءة فقط (لا سياسة كتابة)',
        NOT EXISTS (SELECT 1 FROM pg_policies
                     WHERE schemaname='public' AND tablename='partner_audit' AND cmd <> 'SELECT'), '');

    PERFORM tests.assert('M25: الدالة المساعدة SECURITY DEFINER مع search_path مثبّت',
        (SELECT prosecdef FROM pg_proc WHERE proname='partner_in_manager_farm')
        AND (SELECT proconfig::text LIKE '%search_path%' FROM pg_proc WHERE proname='partner_in_manager_farm'), '');

    PERFORM tests.assert('M25: authenticated ينفّذ partner_in_manager_farm',
        has_function_privilege('authenticated','public.partner_in_manager_farm(uuid)','EXECUTE'), '');

    PERFORM tests.assert('M25: لا صلاحية EXECUTE لـPUBLIC (grantee 0) على الدالة المساعدة',
        NOT EXISTS (
            SELECT 1 FROM pg_proc pr
            CROSS JOIN LATERAL aclexplode(COALESCE(pr.proacl, acldefault('f', pr.proowner))) a
             WHERE pr.proname='partner_in_manager_farm' AND a.grantee=0 AND a.privilege_type='EXECUTE'), '');

    PERFORM tests.assert('M25: anon بلا وصول لأي جدول',
        NOT has_table_privilege('anon','public.partners','SELECT')
        AND NOT has_table_privilege('anon','public.partner_audit','SELECT'), '');

    -- ── B) التجهيز كـsystem_admin ────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);

    INSERT INTO public.partners (id, user_id, name, share_model, percentage) VALUES
        (v_pa, v_admin,  'Partner A', 'percentage', 50),
        (v_pb, NULL,     'Partner B', 'percentage', 30),
        (v_pc, v_worker, 'Partner C', 'percentage', 10),
        (v_pd, v_adminB, 'Partner D', 'percentage', 10);

    INSERT INTO public.profit_distributions (id, farm_id, period_start, period_end) VALUES
        (v_da, v_farmA, DATE '2026-02-01', DATE '2026-02-28'),
        (v_db, v_farmB, DATE '2026-02-01', DATE '2026-02-28');

    INSERT INTO public.profit_distribution_details (id, distribution_id, farm_id, partner_id, share_model)
        VALUES (v_ddpa, v_da, v_farmA, v_pa, 'percentage'),
               (v_ddpc, v_da, v_farmA, v_pc, 'percentage'),
               (v_ddpd, v_db, v_farmB, v_pd, 'percentage');

    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES (v_wpa, v_pa, v_farmA, 100, v_sys),
               (v_wpc, v_pc, v_farmA, 50,  v_sys),
               (v_wpd, v_pd, v_farmB, 70,  v_sys);

    INSERT INTO public.user_roles (user_id, farm_id, role) VALUES
        (v_admin,  v_farmA, 'manager'),
        (v_worker, NULL,    'partner'),
        (v_adminB, v_farmB, 'manager');

    PERFORM public.record_partner_audit(v_farmA, 'added', v_sys, v_pa);
    PERFORM public.record_partner_audit(v_farmA, 'added', v_sys, v_pc);
    PERFORM public.record_partner_audit(v_farmB, 'added', v_sys, v_pd);
    PERFORM tests.assert('M25: التجهيز (شركاء/توزيعات/بنود/سحوبات/أدوار/تدقيق) نجح', true, '');

    -- ── C) partners: self فقط + شركاء "مزرعة المدير" ────────────────────────
    PERFORM tests.set_user(v_sys);
    SELECT count(*) INTO v_n FROM public.partners;
    PERFORM tests.assert('M25: system_admin يرى كل الشركاء (4)', v_n = 4, format('n=%s', v_n));

    PERFORM tests.set_user(v_admin);
    SELECT count(*) INTO v_n FROM public.partners;
    PERFORM tests.assert('M25: مدير A-الشريك يرى نفسه + شركاء مزرعته (2)', v_n = 2, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partners WHERE id = v_pd;
    PERFORM tests.assert('M25: مدير A لا يرى شريك مزرعة B', v_n = 0, format('n=%s', v_n));

    PERFORM tests.set_user(v_worker);
    SELECT count(*) INTO v_n FROM public.partners;
    PERFORM tests.assert('M25: العامل-الشريك يرى صفّه فقط (1)', v_n = 1, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.partners WHERE id = v_pa;
    PERFORM tests.assert('M25: العامل لا يرى شريكاً آخر', v_n = 0, format('n=%s', v_n));

    PERFORM tests.set_user(v_adminB);
    SELECT count(*) INTO v_n FROM public.partners;
    PERFORM tests.assert('M25: مدير B يرى شريك B فقط (1)', v_n = 1, format('n=%s', v_n));

    -- ── D) user_roles: self + أدوار المزرعة ─────────────────────────────────
    PERFORM tests.set_user(v_sys);
    SELECT count(*) INTO v_n FROM public.user_roles;
    PERFORM tests.assert('M25: system_admin يرى كل الأدوار (3)', v_n = 3, format('n=%s', v_n));

    PERFORM tests.set_user(v_admin);
    SELECT count(*) INTO v_n FROM public.user_roles;
    PERFORM tests.assert('M25: مدير A يرى دور مزرعته + دوره الذاتي', v_n = 1, format('n=%s', v_n));

    PERFORM tests.set_user(v_worker);
    SELECT count(*) INTO v_n FROM public.user_roles;
    PERFORM tests.assert('M25: العامل يرى دوره الذاتي (عام)', v_n = 1, format('n=%s', v_n));

    PERFORM tests.set_user(v_adminB);
    SELECT count(*) INTO v_n FROM public.user_roles;
    PERFORM tests.assert('M25: مدير B يرى دور مزرعة B فقط', v_n = 1, format('n=%s', v_n));

    -- ── E) profit_distributions: مدير + شريك ببند ───────────────────────────
    PERFORM tests.set_user(v_sys);
    SELECT count(*) INTO v_n FROM public.profit_distributions;
    PERFORM tests.assert('M25: system_admin يرى كل التوزيعات (2)', v_n = 2, format('n=%s', v_n));

    PERFORM tests.set_user(v_admin);
    SELECT count(*) INTO v_n FROM public.profit_distributions;
    PERFORM tests.assert('M25: مدير A يرى توزيع مزرعته فقط (1)', v_n = 1, format('n=%s', v_n));

    PERFORM tests.set_user(v_worker);
    SELECT count(*) INTO v_n FROM public.profit_distributions;
    PERFORM tests.assert('M25: الشريك-العامل يرى توزيعاً فيه بند له (1)', v_n = 1, format('n=%s', v_n));

    PERFORM tests.set_user(v_adminB);
    SELECT count(*) INTO v_n FROM public.profit_distributions WHERE farm_id = v_farmA;
    PERFORM tests.assert('M25: مدير B لا يرى توزيع مزرعة A', v_n = 0, format('n=%s', v_n));

    -- ── F) profit_distribution_details ──────────────────────────────────────
    PERFORM tests.set_user(v_sys);
    SELECT count(*) INTO v_n FROM public.profit_distribution_details;
    PERFORM tests.assert('M25: system_admin يرى كل البنود (3)', v_n = 3, format('n=%s', v_n));

    PERFORM tests.set_user(v_admin);
    SELECT count(*) INTO v_n FROM public.profit_distribution_details;
    PERFORM tests.assert('M25: مدير A يرى بنود مزرعته (2)', v_n = 2, format('n=%s', v_n));

    PERFORM tests.set_user(v_worker);
    SELECT count(*) INTO v_n FROM public.profit_distribution_details;
    PERFORM tests.assert('M25: الشريك-العامل يرى بنده فقط (1)', v_n = 1, format('n=%s', v_n));
    SELECT count(*) INTO v_n FROM public.profit_distribution_details WHERE id = v_ddpa;
    PERFORM tests.assert('M25: الشريك-العامل لا يرى بند شريك آخر', v_n = 0, format('n=%s', v_n));

    -- ── G) partner_withdrawals ──────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);
    SELECT count(*) INTO v_n FROM public.partner_withdrawals;
    PERFORM tests.assert('M25: system_admin يرى كل السحوبات (3)', v_n = 3, format('n=%s', v_n));

    PERFORM tests.set_user(v_admin);
    SELECT count(*) INTO v_n FROM public.partner_withdrawals;
    PERFORM tests.assert('M25: مدير A يرى سحوبات مزرعته (2)', v_n = 2, format('n=%s', v_n));

    PERFORM tests.set_user(v_worker);
    SELECT count(*) INTO v_n FROM public.partner_withdrawals;
    PERFORM tests.assert('M25: الشريك-العامل يرى سحبه فقط (1)', v_n = 1, format('n=%s', v_n));

    -- ── H) partner_audit: admin + manager + self ────────────────────────────
    PERFORM tests.set_user(v_sys);
    SELECT count(*) INTO v_n FROM public.partner_audit;
    PERFORM tests.assert('M25: system_admin يرى كل سجل التدقيق (3)', v_n = 3, format('n=%s', v_n));

    PERFORM tests.set_user(v_admin);
    SELECT count(*) INTO v_n FROM public.partner_audit;
    PERFORM tests.assert('M25: مدير A يرى تدقيق مزرعته (2)', v_n = 2, format('n=%s', v_n));

    PERFORM tests.set_user(v_worker);
    SELECT count(*) INTO v_n FROM public.partner_audit;
    PERFORM tests.assert('M25: الشريك-العامل يرى تدقيقه فقط (1)', v_n = 1, format('n=%s', v_n));

    PERFORM tests.set_user(v_adminB);
    SELECT count(*) INTO v_n FROM public.partner_audit WHERE farm_id = v_farmA;
    PERFORM tests.assert('M25: مدير B لا يرى تدقيق مزرعة A', v_n = 0, format('n=%s', v_n));

    -- ── I) الكتابة: manager_write للشركاء ───────────────────────────────────
    PERFORM tests.set_user(v_admin);
    UPDATE public.partners SET phone = '0700' WHERE id = v_pa;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM tests.assert('M25: مدير A يعدّل شريك مزرعته', v_n = 1, format('n=%s', v_n));
    UPDATE public.partners SET phone = 'x' WHERE id = v_pd;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM tests.assert('M25: مدير A لا يعدّل شريك مزرعة B', v_n = 0, format('n=%s', v_n));

    -- ── J) الكتابة: manager_write للأدوار ───────────────────────────────────
    INSERT INTO public.user_roles (user_id, farm_id, role) VALUES (v_worker, v_farmA, 'supervisor');
    PERFORM tests.assert('M25: مدير A يمنح دوراً على مزرعته', true, '');
    BEGIN
        INSERT INTO public.user_roles (user_id, farm_id, role) VALUES (v_worker, v_farmB, 'supervisor');
        PERFORM tests.assert('M25: مدير A لا يمنح دوراً على مزرعة أخرى', false, 'نجح الإدخال');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M25: مدير A لا يمنح دوراً على مزرعة أخرى', true, SQLERRM);
    END;

    -- ── K) الكتابة: سحب الشريك pending لنفسه فقط ────────────────────────────
    PERFORM tests.set_user(v_worker);
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES ('33333333-0000-0000-0000-0000000000c9', v_pc, v_farmA, 7, v_worker);
    PERFORM tests.assert('M25: الشريك-العامل ينشئ سحباً pending لنفسه', true, '');
    BEGIN
        INSERT INTO public.partner_withdrawals (partner_id, farm_id, amount, requested_by)
            VALUES (v_pa, v_farmA, 5, v_worker);
        PERFORM tests.assert('M25: الشريك لا ينشئ لشريك آخر', false, 'نجح الإدخال');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M25: الشريك لا ينشئ لشريك آخر', true, SQLERRM);
    END;

    -- ── L) الكتابة: مدير يعدّل سحب مزرعته ───────────────────────────────────
    PERFORM tests.set_user(v_admin);
    UPDATE public.partner_withdrawals SET status = 'approved', reviewed_by = v_admin WHERE id = v_wpc;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM tests.assert('M25: مدير A يعتمد سحب مزرعته', v_n = 1, format('n=%s', v_n));

    PERFORM tests.set_user(v_adminB);
    UPDATE public.partner_withdrawals SET status = 'approved', reviewed_by = v_adminB WHERE id = v_wpa;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM tests.assert('M25: مدير B لا يعدّل سحب مزرعة A', v_n = 0, format('n=%s', v_n));

    -- ── M) partner_audit: لا كتابة من العميل إطلاقاً ────────────────────────
    PERFORM tests.assert('M25: authenticated بلا INSERT/UPDATE/DELETE على partner_audit',
        NOT has_table_privilege('authenticated','public.partner_audit','INSERT')
        AND NOT has_table_privilege('authenticated','public.partner_audit','UPDATE')
        AND NOT has_table_privilege('authenticated','public.partner_audit','DELETE'), '');

    PERFORM tests.set_user(v_sys);
    BEGIN
        INSERT INTO public.partner_audit (farm_id, action, changed_by) VALUES (v_farmA, 'added', v_sys);
        PERFORM tests.assert('M25: حتى system_admin لا يكتب التدقيق مباشرةً', false, 'نجح الإدخال');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('M25: حتى system_admin لا يكتب التدقيق مباشرةً', true, SQLERRM);
    END;

    RAISE NOTICE 'p0_partner_rls: انتهى — الستة جداول والصلاحيات والعزل';
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_partner_rls: كل الفحوص PASS — admin/manager/self، لا cross-farm، التدقيق append-only';
END; $final$;

ROLLBACK;
