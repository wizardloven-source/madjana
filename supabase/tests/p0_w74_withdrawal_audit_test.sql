-- ============================================================================
--  p0_w74_withdrawal_audit_test.sql
--  خطة W7.4: محفّز تدقيق سحوبات الشركاء (trg_partner_withdrawals_audit).
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
    v_farmA  uuid := '00000000-0000-0000-0000-000000000001';

    v_pw  uuid := '66666666-0000-0000-0000-0000000000a1';
    v_w1  uuid := '77777777-0000-0000-0000-0000000000a1';
    v_w2  uuid := '77777777-0000-0000-0000-0000000000a2';
    v_w3  uuid := '77777777-0000-0000-0000-0000000000a3';
    v_w4  uuid := '77777777-0000-0000-0000-0000000000a4';

    v_n          int;
    v_changed_by uuid;
BEGIN
    -- ── A) البنية ────────────────────────────────────────────────────────────
    PERFORM tests.assert('W7.4: الدالة موجودة وSECURITY DEFINER',
        EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'audit_partner_withdrawal'
                   AND p.prosecdef), '');

    PERFORM tests.assert('W7.4: المحفّز معلّق مرة واحدة',
        (SELECT count(*) FROM pg_trigger
          WHERE NOT tgisinternal AND tgname = 'trg_partner_withdrawals_audit'
            AND tgrelid = 'public.partner_withdrawals'::regclass) = 1, '');

    PERFORM tests.assert('W7.4: المحفّز AFTER وليس BEFORE',
        (SELECT (tgtype & 2) = 0 FROM pg_trigger
          WHERE NOT tgisinternal AND tgname = 'trg_partner_withdrawals_audit'), '');

    -- ── B) التجهيز ────────────────────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);
    INSERT INTO public.partners (id, user_id, name, share_model, percentage)
        VALUES (v_pw, v_worker, 'W74 Partner', 'percentage', 10);
    INSERT INTO public.user_roles (user_id, farm_id, role)
        VALUES (v_admin, v_farmA, 'manager');

    -- ── C) طلب الشريك: withdrawal_requested بـchanged_by = الطالب ─────────────
    PERFORM tests.set_user(v_worker);
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES (v_w1, v_pw, v_farmA, 50, v_worker);

    SELECT count(*) INTO v_n FROM public.partner_audit
     WHERE action = 'withdrawal_requested' AND partner_id = v_pw;
    PERFORM tests.assert('W7.4: INSERT يُسجَّل withdrawal_requested (1)', v_n = 1, format('n=%s', v_n));

    SELECT changed_by INTO v_changed_by FROM public.partner_audit
     WHERE action = 'withdrawal_requested' AND partner_id = v_pw;
    PERFORM tests.assert('W7.4: changed_by = الطالب (auth.uid())', v_changed_by = v_worker, '');

    PERFORM tests.assert('W7.4: new_values تحمل معرّف السحب',
        (SELECT (new_values->>'withdrawal_id')::uuid = v_w1
           FROM public.partner_audit
          WHERE action = 'withdrawal_requested' AND partner_id = v_pw), '');

    -- ── D) اعتماد المدير: withdrawal_approved ─────────────────────────────────
    PERFORM tests.set_user(v_admin);
    PERFORM public.approve_withdrawal(v_w1, v_admin);

    SELECT count(*) INTO v_n FROM public.partner_audit
     WHERE action = 'withdrawal_approved' AND partner_id = v_pw;
    PERFORM tests.assert('W7.4: الاعتماد يُسجَّل withdrawal_approved (1)', v_n = 1, format('n=%s', v_n));

    SELECT changed_by INTO v_changed_by FROM public.partner_audit
     WHERE action = 'withdrawal_approved' AND partner_id = v_pw;
    PERFORM tests.assert('W7.4: changed_by = المعتمد', v_changed_by = v_admin, '');

    -- سطر الحالة (مسار UPDATE) يحمل withdrawal_id منذ تعديل W7.4، فتطابق
    -- شاشة التفاصيل سجل هذا السحب مباشرة بلا اعتماد على التطابق الزمني.
    PERFORM tests.assert('W7.4: سطر الاعتماد يحمل withdrawal_id',
        (SELECT (new_values->>'withdrawal_id')::uuid = v_w1
           FROM public.partner_audit
          WHERE action = 'withdrawal_approved' AND partner_id = v_pw), '');

    -- ── E) الصرف: withdrawal_paid ─────────────────────────────────────────────
    UPDATE public.partner_withdrawals
       SET status = 'paid', payment_method = 'cash'
     WHERE id = v_w1;

    SELECT count(*) INTO v_n FROM public.partner_audit
     WHERE action = 'withdrawal_paid' AND partner_id = v_pw;
    PERFORM tests.assert('W7.4: الصرف يُسجَّل withdrawal_paid (1)', v_n = 1, format('n=%s', v_n));

    SELECT changed_by INTO v_changed_by FROM public.partner_audit
     WHERE action = 'withdrawal_paid' AND partner_id = v_pw;
    PERFORM tests.assert('W7.4: paid changed_by = اللافتز', v_changed_by = v_admin, '');

    -- ── F) الرفض: withdrawal_rejected ─────────────────────────────────────────
    PERFORM tests.set_user(v_worker);
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES (v_w2, v_pw, v_farmA, 30, v_worker);

    PERFORM tests.set_user(v_admin);
    UPDATE public.partner_withdrawals
       SET status = 'rejected', rejection_reason = 'نقص رصيد'
     WHERE id = v_w2;

    SELECT count(*) INTO v_n FROM public.partner_audit
     WHERE action = 'withdrawal_rejected' AND partner_id = v_pw;
    PERFORM tests.assert('W7.4: الرفض يُسجَّل withdrawal_rejected (1)', v_n = 1, format('n=%s', v_n));

    -- ── G) تحديث غير-حالة بلا تسجيل + cancelled بلا تسجيل ────────────────────
    PERFORM tests.set_user(v_worker);
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES (v_w3, v_pw, v_farmA, 10, v_worker);

    -- 3 طلبات + اعتماد + صرف + رفض = 6
    SELECT count(*) INTO v_n FROM public.partner_audit WHERE partner_id = v_pw;
    PERFORM tests.assert('W7.4: حتى الآن 6 سجلات للشريك', v_n = 6, format('n=%s', v_n));

    PERFORM tests.set_user(v_admin);
    UPDATE public.partner_withdrawals SET notes = 'ملاحظة' WHERE id = v_w3;
    SELECT count(*) INTO v_n FROM public.partner_audit WHERE partner_id = v_pw;
    PERFORM tests.assert('W7.4: تحديث غير-حالة لا يُسجَّل', v_n = 6, format('n=%s', v_n));

    UPDATE public.partner_withdrawals SET status = 'cancelled' WHERE id = v_w3;
    SELECT count(*) INTO v_n FROM public.partner_audit WHERE partner_id = v_pw;
    PERFORM tests.assert('W7.4: cancelled بلا سجل (بلا قيمة مطابقة)', v_n = 6, format('n=%s', v_n));

    -- ── H) سلم الحالة: انتقال مرفوض لا يترك سجلاً ─────────────────────────────
    BEGIN
        UPDATE public.partner_withdrawals SET status = 'paid' WHERE id = v_w2;
        PERFORM tests.assert('W7.4: rejected -> paid مرفوض', false, 'نجح');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('W7.4: rejected -> paid مرفوض',
            SQLERRM LIKE '%INVALID_STATUS_TRANSITION%', SQLERRM);
    END;
    SELECT count(*) INTO v_n FROM public.partner_audit WHERE partner_id = v_pw;
    PERFORM tests.assert('W7.4: المحاولة الفاشلة لا تترك سجلاً', v_n = 6, format('n=%s', v_n));

    -- ── I) actor احتياطي: بلا جلسة يُستخدم requested_by المخزَن ──────────────
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '{"role":"authenticated"}', true);
    INSERT INTO public.partner_withdrawals (id, partner_id, farm_id, amount, requested_by)
        VALUES (v_w4, v_pw, v_farmA, 15, v_worker);
    SET ROLE test_runner;

    -- القَطع عن الجلسة (بلا sub) يجعل auth.uid() = NULL، فتحجب سياسات
    -- partner_audit الثلاث كل الصفوف — والفحص هنا عن كتابة المحفّز لا عن RLS،
    -- لذا تُستعاد جلسة مدير المزرعة (audit_manager_read) قبل القراءة.
    PERFORM tests.set_user(v_admin);

    SELECT count(*) INTO v_n FROM public.partner_audit
     WHERE action = 'withdrawal_requested' AND partner_id = v_pw;
    PERFORM tests.assert('W7.4: بلا جلسة يُسجَّل الطلب (4 طلبات)', v_n = 4, format('n=%s', v_n));

    SELECT changed_by INTO v_changed_by FROM public.partner_audit
     WHERE (new_values->>'withdrawal_id')::uuid = v_w4;
    PERFORM tests.assert('W7.4: بلا جلسة changed_by = requested_by', v_changed_by = v_worker, '');

    RAISE NOTICE 'p0_w74_withdrawal_audit: انتهى — محفّز التدقيق يغطي الطلب/الاعتماد/الرفض/الصرف';
END;
$s$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_w74_withdrawal_audit: كل الفحوص PASS';
END; $final$;

ROLLBACK;
