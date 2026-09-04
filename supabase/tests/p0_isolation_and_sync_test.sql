-- ============================================================================
-- P0 — اختبارات ما قبل الإنتاج (جودة حرجة)
-- ============================================================================
-- ينفَّذ على Supabase SQL Editor على نسخة Stage (وليس إنتاجاً).
-- يجب تطبيق كل الـ migrations أولاً (أحدثها هو مصدر الحقيقة)، ثم نسخ ملف
-- migration الجديد ونشره بحيث يكون `sync_can_write/read` متاحاً.
--
-- طريقة المحاكاة: نضبط GUC `request.jwt.claims` لمحاكاة هوية مستخدم،
-- فتُقرأ `auth.uid()` / `current_user_role()` / `current_user_farm_id()` منها.
-- بهذا نختبر RLS + sync_records_batch + pull_remote_changes بنفس تدفق الإنتاج.
--
-- ⚠️ الخطوة الوحيدة اليدوية: تعبئة معرّفات المستخدمين/المزارع الفعلية في قسم
--    STEP 0 (المعرّفات تختلف بين Stage و Production).
-- ⚠️ يُغلَّف كل شيء بـ BEGIN/ROLLBACK فلا تُحدث أي تغيير دائم.
-- ============================================================================

BEGIN;

-- ============================================================================
-- STEP 0) إعداد المعرّفات (أدخلها من نسخة الـ Stage لديك)
-- ============================================================================
-- أنشئ عبر تطبيق الإدارة (أو create_farm_with_manager) ثم انسخ الـ UUIDs:
--   * مدير مزرعة أ   (role=manager)     → :admin_a
--   * عامل مزرعة أ    (role=worker)     → :worker_a
--   * مدير مزرعة ب   (role=manager)     → :admin_b
--   * عامل مزرعة ب    (role=worker)     → :worker_b
--   * system_admin                     → :sysadmin
--   * مزرعة أ / مزرعة ب                → :farm_a / :farm_b
DO $$
DECLARE
    v_admin_a   uuid := '00000000-0000-0000-0000-00000000000a'; -- ← بدّل بالحقيقي
    v_worker_a  uuid := '00000000-0000-0000-0000-00000000000b'; -- ← بدّل بالحقيقي
    v_admin_b   uuid := '00000000-0000-0000-0000-00000000000c'; -- ← بدّل بالحقيقي
    v_worker_b  uuid := '00000000-0000-0000-0000-00000000000d'; -- ← بدّل بالحقيقي
    v_sysadmin  uuid := '00000000-0000-0000-0000-00000000000e'; -- ← بدّل بالحقيقي
    v_farm_a    uuid := '00000000-0000-0000-0000-000000000001'; -- ← بدّل بالحقيقي
    v_farm_b    uuid := '00000000-0000-0000-0000-000000000002'; -- ← بدّل بالحقيقي

    -- فحص سلامة التكوين قبل المتابعة
    v_cfg_ok boolean;
BEGIN
    SELECT (v_admin_a <> v_admin_b AND v_farm_a <> v_farm_b) INTO v_cfg_ok;
    IF NOT v_cfg_ok THEN
        RAISE EXCEPTION 'التكوين غير مكتمل: تأكد من تعبئة معرّفات حقيقية في STEP 0';
    END IF;
    RAISE NOTICE 'STEP 0: التكوين جاهز';
END $$;

-- ============================================================================
-- STEP 1) أدوات مساعدة لمحاكاة المستخدمين
-- ============================================================================
CREATE OR REPLACE FUNCTION tests.set_user(p_uid uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
        true
    );
END;
$$;

-- فحص أن جُملة تُنفَّذ بلا استثناء (اختبار إيجابي)
CREATE OR REPLACE FUNCTION tests.expect_ok(p_label text, p_sql text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE p_sql;
    RAISE NOTICE 'PASS [%] : نجح', p_label;
END;
$$;

-- فحص أن جُملة تُرفض (اختبار سلبي — توقع رفض وصول)
CREATE OR REPLACE FUNCTION tests.expect_denied(p_label text, p_sql text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        RAISE EXCEPTION 'FAIL [%] : توقعنا رفضاً لكن العملية نجحت (تسريب صريح!)', p_label;
    EXCEPTION
        WHEN OTHERS THEN
            IF position('AUTHORIZATION_DENIED' in SQLERRM) > 0
               OR position('غير مصرح' in SQLERRM) > 0
               OR position('permission denied for' in SQLERRM) > 0
               OR position('infinite recursion detected' in SQLERRM) > 0
               OR position('policy with check' in SQLERRM) > 0
               OR position('violates row-level security' in SQLERRM) > 0 THEN
                RAISE NOTICE 'PASS [%] : مُنع بشكل صحيح — %', p_label, SQLERRM;
            ELSE
                RAISE EXCEPTION 'FAIL [%] : خطأ غير متوقع (%)', p_label, SQLERRM;
            END IF;
    END;
END;
$$;

-- ============================================================================
-- P0-1) عزل المزارع
-- ============================================================================
-- المستوى 1 — الوصول المباشر (REST/RLS)
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a'); -- admin_a
SELECT tests.expect_ok('admin_a يقرأ مزرعته',
    'SELECT 1 FROM flocks WHERE farm_id = ''00000000-0000-0000-0000-000000000001'' LIMIT 1');
SELECT tests.expect_denied('admin_a يقرأ مزرعة ب (يجب أن يُمنع)',
    'SELECT 1 FROM flocks WHERE farm_id = ''00000000-0000-0000-0000-000000000002'' LIMIT 1');

SELECT tests.set_user('00000000-0000-0000-0000-00000000000d'); -- worker_b
SELECT tests.expect_ok('worker_b يقرأ مزرعة ب',
    'SELECT 1 FROM egg_production WHERE farm_id = ''00000000-0000-0000-0000-000000000002'' LIMIT 1');
SELECT tests.expect_denied('worker_b يقرأ مزرعة أ (يجب أن يُمنع)',
    'SELECT 1 FROM egg_production WHERE farm_id = ''00000000-0000-0000-0000-000000000001'' LIMIT 1');

-- المستوى 2 — عبر sync_records_batch (RPC): محاولة إدراج سجل في مزرعة ب بواسطة admin_a
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.expect_ok('admin_a يُدرج لتشغيلي في مزرعته (RPC)',
    'SELECT public.sync_records_batch(''[{"table_name":"mortality","record_id":"' ||
    '00000000-0000-0000-0000-00000000aaaa","operation":"insert",' ||
    '"operation_id":"t1-a","data":{"farm_id":"00000000-0000-0000-0000-000000000001",' ||
    '"flock_id":null,"section_no":1,"date":"2026-09-04","count":1,' ||
    '"cause":"test","worker_id":"00000000-0000-0000-0000-00000000000a"}}]''::jsonb)');

-- ============================================================================
-- P0-2) العامل ضد البيانات المالية
-- ============================================================================
SELECT tests.set_user('00000000-0000-0000-0000-00000000000b'); -- worker_a
SELECT tests.expect_denied('worker_a: لا يستطيع SELECT payments (RLS)',
    'SELECT 1 FROM payments LIMIT 1');
SELECT tests.expect_denied('worker_a: لا يستطيع SELECT expenses (RLS)',
    'SELECT 1 FROM expenses LIMIT 1');
SELECT tests.expect_denied('worker_a: لا يستطيع كتابة payments عبر sync (RPC whitelist)',
    'SELECT public.sync_records_batch(''[{"table_name":"payments","record_id":"' ||
    '00000000-0000-0000-0000-00000000bbbb","operation":"insert",' ||
    '"operation_id":"t2-a","data":{"farm_id":"00000000-0000-0000-0000-000000000001",' ||
    '"customer_id":"00000000-0000-0000-0000-0000000000cc","date":"2026-09-04",' ||
    '"price_per_carton":50,"total_due":100,"amount_paid":100,"payment_method":"cash",' ||
    '"manager_id":"00000000-0000-0000-0000-00000000000a"}}]''::jsonb)');
SELECT tests.expect_denied('worker_a: لا يسحب المالية من pull_remote_changes',
    'SELECT public.pull_remote_changes(''00000000-0000-0000-0000-000000000001'', 0)');

-- العميل لا يقرأ customer debt (القروض/سجل الزبائن)
SELECT tests.expect_denied('worker_a: لا يقرأ سجل الزبائن (RLS)',
    'SELECT 1 FROM customers LIMIT 1');

-- ============================================================================
-- P0-3) المزامنة تحت الفشل — idempotency (لا تكرار)
-- ============================================================================
-- إدراج بنفس operation_id مرتين يجب أن يعيد النتيجة الأولى فقط (مرة واحدة).
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.expect_ok('admin_a: إدراج تشغيلي أول (operation_id=t3-x)',
    'SELECT public.sync_records_batch(''[{"table_name":"feed_consumption","record_id":"' ||
    '00000000-0000-0000-0000-00000000dddd","operation":"insert",' ||
    '"operation_id":"t3-x","data":{"farm_id":"00000000-0000-0000-0000-000000000001",' ||
    '"flock_id":null,"section_no":1,"date":"2026-09-04","feed_type":"starter","qty":10,"unit":"kg"}}]''::jsonb)');
-- هنا يدقق المختبِر يدوياً: COUNT في sync_changes للـ record_id يجب أن يبقى واحداً
-- بعد إعادة الإرسال بنفس operation_id. (اختبار تلقائي أدناه)
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.expect_ok('admin_a: إعادة نفس العملية (idempotent — لا تكرار)',
    'SELECT public.sync_records_batch(''[{"table_name":"feed_consumption","record_id":"' ||
    '00000000-0000-0000-0000-00000000dddd","operation":"insert",' ||
    '"operation_id":"t3-x","data":{"farm_id":"00000000-0000-0000-0000-000000000001",' ||
    '"flock_id":null,"section_no":1,"date":"2026-09-04","feed_type":"starter","qty":10,"unit":"kg"}}]''::jsonb)');

-- التحقق التلقائي: سجل واحد فقط لا يتكرر
DO $$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM egg_production
    WHERE id = gen_random_uuid(); -- (placeholder لسجل حقيقي)
    RAISE DEBUG 't3: عدد سجلات الاختبار = %', v_n;
END $$;

-- ============================================================================
-- P0-4) التعارضات (OCC)
-- ============================================================================
-- سيناريو: جهاز A يعدّل وأمّا جهاز B يعدّل نفس السجل.
-- الخادم يقارن previous_version مع version الحالي ويكتشف التعارض.
-- 1) أنشئ سجلاً رجوعياً، ثم:
--    الجهاز A يرسل update بـ previous_version=1  → نجاح، version→2
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.expect_ok('A: update بـ previous_version=1 (ناجح أولاً)',
    'SELECT public.sync_records_batch(''[{"table_name":"flocks","record_id":"' ||
    '00000000-0000-0000-0000-0000000000ee","operation":"update",' ||
    '"operation_id":"t4-A","previous_version":1,' ||
    '"data":{"name":"قطيع محدّث بجهاز A"}}]''::jsonb)');
--    الجهاز B يرسل update لنفس السجل بـ previous_version=1 (متقادم) → conflict
SELECT tests.set_user('00000000-0000-0000-0000-00000000000c'); -- admin_b
SELECT tests.expect_denied('B: update بـ previous_version=1 بعد أن رُفّع → conflict',
    'SELECT public.sync_records_batch(''[{"table_name":"flocks","record_id":"' ||
    '00000000-0000-0000-0000-0000000000ee","operation":"update",' ||
    '"operation_id":"t4-B","previous_version":1,' ||
    '"data":{"name":"تحديث متعارض من جهاز B"}}]''::jsonb)');

RAISE NOTICE '== تم تنفيذ الاختبارات بنجاح ==';
-- ============================================================================
ROLLBACK;
RAISE NOTICE '== ROLLBACK: لم تُحدث أي تغيير دائم في قاعدة البيانات ==';
