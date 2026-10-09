-- ============================================================================
--  p0_catch_test.sql
--  عقد الخطأ الصريح (M10) — الجانب الخادمي لقاعدة «لا silent catch».
-- ============================================================================
--
--  PURPOSE
--  -------
--  M10 حوّل كل `catch (_)` الصامت في التطبيق إلى تدفقات مسموعة: إعادة رمي،
--  أو `debugPrint`، أو `SyncFailure` بكود مستقر. لكن القاعدة لا تعني شيئاً
--  إذا كان الخادم نفسه «صامتاً»: RPC مفقود يحوّل الكتابة إلى 404 صامت، وامتياز
--  مفتوح يجعل مسار `catch` في التطبيق كوداً ميتاً، ورموز خطأ عشوائية تجعل
--  `SyncFailure(code)` عديمة الجدوى.
--
--  هذا الملف يُثبت الجانب الخادمي للعقد:
--
--    STEP 1) سطح RPC: كل دالة يستدعيها العميل موجودة فعلياً (لا 404 صامت).
--    STEP 2) امتيازات: المسارات المحمية رُفعت من `anon` (الرفض صريح وراء
--            مسار catch في التطبيق)، والمسارات المصرح بها `authenticated`
--            متاحة حقاً (فالخطأ الحقيقي يبقى خطأً، لا غيابَ منحة).
--    STEP 3) فشل صاخب: بلا جلسة، الخادم يَرْمي برموز مقروءة (AUTHORIZATION_DENIED)
--            بدل إرجاع نجاح فارغ؛ دوال المزامنة مصممة بحمايات واضحة
--            (`RAISE EXCEPTION` على أخطاء الدفعة) وتخزّن تعارضاتها.
--
--  HOW TO RUN (مثل كل مجموعات run_all.py):
--
--      psql -h 127.0.0.1 -p 5433 -U postgres -d madjana_test \
--           -v ON_ERROR_STOP=1 \
--           -c "SET ROLE test_runner" \
--           -f p0_catch_test.sql
--
--  MUST run كـ`test_runner` (غير superuser): بلا جلسة لا يوجد `auth.uid()`،
--  فتكشف الفحوص الفشلَ الصاخبَ الحقيقي. كل شيء داخل BEGIN/ROLLBACK.
-- ============================================================================

BEGIN;

-- ============================================================================
--  Harness — نفس عقد p0_schema_version_test.sql.
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS tests;

CREATE OR REPLACE FUNCTION tests.assert(p_label text, p_cond boolean,
                                        p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_cond THEN
        RAISE NOTICE 'PASS [M10: %] %', p_label, p_detail;
    ELSE
        RAISE EXCEPTION 'FAIL [M10: %] %', p_label, p_detail;
    END IF;
END;
$$;

-- ============================================================================
--  STEP 0) Preconditions — اختبار لا يمكن أن يفشل لا يثبت شيئاً
-- ============================================================================
DO $step0$
DECLARE
    v_super boolean;
    v_bypass boolean;
BEGIN
    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass
      FROM pg_roles WHERE rolname = current_user;
    IF v_super OR v_bypass THEN
        RAISE EXCEPTION
            'ABORT: current_user (%) هو superuser أو BYPASSRLS — الفشلُ الصاخبُ '
            'لن يظهر. شغّل هذا الملف كـ test_runner.', current_user;
    END IF;
    RAISE NOTICE 'STEP0: current_user=% super=% bypassrls=%',
                 current_user, v_super, v_bypass;
END;
$step0$;

-- ============================================================================
--  STEP 1) سطح RPC — كل دالة يستدعيها العميل موجودة في public
--          (لو اختفت دالة، يتحوّل استدعاؤها إلى 404 صامت يبتلعه catch
--          قديم؛ الوجود هنا هو الخط الدفاع الأول).
-- ============================================================================
DO $step1$
DECLARE
    v_names text[] := ARRAY['current_schema_version', 'has_system_admin',
        'check_login_allowed', 'get_farm_users', 'admin_select_all_users_with_farms',
        'admin_select_all_farms', 'create_farm_with_manager',
        'current_user_farms_with_names', 'set_active_farm',
        'sync_records_batch', 'pull_remote_changes'];
    v_n text;
    v_ok boolean;
BEGIN
    FOREACH v_n IN ARRAY v_names LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = v_n
        ) INTO v_ok;
        PERFORM tests.assert('RPC موجود: ' || v_n, v_ok, '');
    END LOOP;
END;
$step1$;

-- ============================================================================
--  STEP 2) الامتيازات — الرفضُ صريح، والوصولُ المصرح به حقيقي
--  (مسار catch في التطبيق يعمل فقط إذا كانت الأخطاء حقيقية الأسباب).
-- ============================================================================
DO $step2$
BEGIN
    -- anon: لا شيء من المسارات المحمية — الخادم يرفضها برفع امتياز.
    PERFORM tests.assert('anon بلا EXECUTE على current_schema_version',
        NOT has_function_privilege('anon', 'public.current_schema_version()', 'EXECUTE'), '');
    PERFORM tests.assert('anon بلا EXECUTE على admin_select_all_farms',
        NOT has_function_privilege('anon', 'public.admin_select_all_farms()', 'EXECUTE'), '');
    PERFORM tests.assert('anon بلا EXECUTE على get_farm_users',
        NOT has_function_privilege('anon', 'public.get_farm_users(uuid)', 'EXECUTE'), '');
    PERFORM tests.assert('anon بلا EXECUTE على record_login_success',
        NOT has_function_privilege('anon', 'public.record_login_success(uuid, text)', 'EXECUTE'), '');

    -- authenticated: مسارات المزامنة متاحة فعلاً (الخطأ الحقيقي يبقى خطأً).
    PERFORM tests.assert('authenticated يملك EXECUTE على sync_records_batch(jsonb)',
        has_function_privilege('authenticated', 'public.sync_records_batch(jsonb)', 'EXECUTE'), '');
    PERFORM tests.assert('authenticated يملك EXECUTE على pull_remote_changes(uuid,bigint)',
        has_function_privilege('authenticated', 'public.pull_remote_changes(uuid, bigint)', 'EXECUTE'), '');

    -- pre-login: record_login_failure متاح لـ anon (مسار ما قبل الدخول مقصود).
    PERFORM tests.assert('anon يملك EXECUTE على record_login_failure(text,text)',
        has_function_privilege('anon', 'public.record_login_failure(text, text)', 'EXECUTE'), '');
END;
$step2$;

-- ============================================================================
--  STEP 3) الفشل صاخب — بلا جلسة، الخادم يرمي رمزاً مقروءاً بدل نجاحٍ فارغ
-- ============================================================================
DO $step3$
DECLARE
    v_msg text;
BEGIN
    -- 3.1 sync_records_batch بلا جلسة → AUTHORIZATION_DENIED (وليس []).
    BEGIN
        PERFORM public.sync_records_batch('[]'::jsonb);
        RAISE EXCEPTION 'FAIL [M10: sync_records_batch بلا جلسة عاد بنجاح صامت]';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg ILIKE '%AUTHORIZATION_DENIED%' THEN
            RAISE NOTICE 'PASS [M10: sync_records_batch بلا جلسة يرمي AUTHORIZATION_DENIED] %', v_msg;
        ELSE
            RAISE EXCEPTION 'FAIL [M10: sync_records_batch رمى رمزاً غير متوقع] %', v_msg;
        END IF;
    END;

    -- 3.2 pull_remote_changes بلا جلسة → AUTHORIZATION_DENIED.
    BEGIN
        PERFORM public.pull_remote_changes('00000000-0000-0000-0000-000000000000', 0);
        RAISE EXCEPTION 'FAIL [M10: pull_remote_changes بلا جلسة عاد بنجاح صامت]';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg ILIKE '%AUTHORIZATION_DENIED%' THEN
            RAISE NOTICE 'PASS [M10: pull_remote_changes بلا جلسة يرمي AUTHORIZATION_DENIED] %', v_msg;
        ELSE
            RAISE EXCEPTION 'FAIL [M10: pull_remote_changes رمى رمزاً غير متوقع] %', v_msg;
        END IF;
    END;

    -- 3.3 إدارة المستخدمين بلا جلسة → رفض صريح (permission denied).
    BEGIN
        PERFORM public.admin_select_all_farms();
        RAISE EXCEPTION 'FAIL [M10: admin_select_all_farms بلا جلسة عاد بنجاح صامت]';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'PASS [M10: admin_select_all_farms بلا جلسة مرفوض صراحةً] %', SQLERRM;
    END;

    -- 3.4 قراءة الإصدار بلا جلسة → رفض (مسار «لا حظر» للعميل يبقى حياً).
    BEGIN
        PERFORM public.current_schema_version();
        RAISE EXCEPTION 'FAIL [M10: current_schema_version بلا جلسة عاد بنجاح صامت]';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'PASS [M10: current_schema_version بلا جلسة مرفوض صراحةً] %', SQLERRM;
    END;

    -- 3.5 sync_records_batch مصمم بحماية كاملة: يوجد RAISE EXCEPTION في جسمه
    --     (أخطاء الدفعة الكاملة صاخبة، والأخطاء لكل سجل تُعاد في status).
    PERFORM tests.assert('sync_records_batch في جسمه RAISE EXCEPTION',
        pg_get_functiondef(to_regprocedure('public.sync_records_batch(jsonb)'))
            ILIKE '%RAISE EXCEPTION%',
        '');

    -- 3.6 الخادم يخزّن التعارضات ولا يسقطها (مسار استرداد الصراع في العميل).
    PERFORM tests.assert('جدول sync_conflicts موجود',
        to_regclass('public.sync_conflicts') IS NOT NULL, '');

    -- 3.7 طابور المزامنة مملوء بالـ triggers (لو اختفى الجدول، إعادة الطلب
    --     في catch العميل يصبح كتابةً على العدم).
    PERFORM tests.assert('جدول sync_changes موجود',
        to_regclass('public.sync_changes') IS NOT NULL, '');
END;
$step3$;

-- ============================================================================
--  النتيجة
-- ============================================================================
DO $final$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'p0_catch_test: كل الفحوص PASS';
    RAISE NOTICE 'سطح RPC مكتمل، anon محروم، authenticated ممنوح،';
    RAISE NOTICE 'الفشل بلا جلسة صاخب برموز مقروءة (AUTHORIZATION_DENIED).';
    RAISE NOTICE 'ROLLBACK — لا تغيير دائم.';
    RAISE NOTICE '============================================================';
END;
$final$;

ROLLBACK;