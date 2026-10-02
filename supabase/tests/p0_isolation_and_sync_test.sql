-- ============================================================================
-- P0 — اختبارات ما قبل الإنتاج (جودة حرجة)
-- ============================================================================
-- تنفَّذ على قاعدة مُطبَّق عليها كل الـ migrations (مصدر الحقيقة)، أو على نسخة
-- Stage عبر SQL Editor. تُغلَّف بـ BEGIN/ROLLBACK فلا تُحدث أي تغيير دائم.
--
-- طريقة المحاكاة: نضبط GUC `request.jwt.claims` لمحاكاة هوية مستخدم، فتُقرأ
-- `auth.uid()` / `current_user_role()` / `current_user_farm_id()` منها. بهذا نختبر
-- RLS + sync_records_batch + pull_remote_changes بنفس تدفق الإنتاج.
--
-- ⚠️ local_fixtures.sql يوفّر المعرّفات التالية محلياً (00000000-…-0000a إلخ).
--    على Stage استبدلها في STEP 0 بالمعرّفات الحقيقية.
-- ============================================================================

BEGIN;

-- ============================================================================
-- STEP 0) المعرّفات
-- ============================================================================
DO $$
DECLARE
    v_admin_a   uuid := '00000000-0000-0000-0000-00000000000a';
    v_worker_a  uuid := '00000000-0000-0000-0000-00000000000b';
    v_admin_b   uuid := '00000000-0000-0000-0000-00000000000c';
    v_sysadmin  uuid := '00000000-0000-0000-0000-00000000000e';
    v_farm_a    uuid := '00000000-0000-0000-0000-000000000001';
    v_farm_b    uuid := '00000000-0000-0000-0000-000000000002';
    v_cfg_ok    boolean;
BEGIN
    SELECT (v_admin_a <> v_admin_b AND v_farm_a <> v_farm_b) INTO v_cfg_ok;
    IF NOT v_cfg_ok THEN
        RAISE EXCEPTION 'التكوين غير مكتمل: تأكد من تعبئة معرّفات مختلفة';
    END IF;
    RAISE NOTICE 'STEP 0: التكوين جاهز';
END $$;

-- ============================================================================
-- STEP 1) أدوات مساعدة
-- ============================================================================
-- ملاحظة مهمة حول الدلالات:
--   * SELECT تحت RLS لا يرمي استثناءً عند التجاوز — الصفوف تُفلَت بصمت وتُرجع
--     0 صف. لذلك فحص التجاوز على القراءة هو expect_no_rows وليس expect_denied.
--     الاختبار السابق كان يطلب استثناءً على SELECT فيُبلّغ "تسريب صريح" رغم أن
--     السلوك كان صحيحاً تماماً.
--   * الكتابة (INSERT/UPDATE/DELETE) و RPC المسموحة تُرجع status='error' داخل
--     نتيجة الدالة بدل أن ترمي استثناءً. لذلك expect_denied يجب أن يفحص
--     status/message لا الاستثناء.
--   * pull_remote_changes ترمي استثناءً حقيقياً عند تجاوز المزرعة.
CREATE OR REPLACE FUNCTION tests.set_user(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
        true
    );
END;
$$;

CREATE OR REPLACE FUNCTION tests.assert(p_label text, p_cond boolean,
                                        p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_cond THEN
        RAISE NOTICE 'PASS [%] %', p_label, p_detail;
    ELSE
        RAISE EXCEPTION 'FAIL [%] %', p_label, p_detail;
    END IF;
END;
$$;

-- فحص أن الاستعلام يُنفَّذ بلا استثناء (اختبار إيجابي)
CREATE OR REPLACE FUNCTION tests.expect_ok(p_label text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RAISE NOTICE 'PASS [%] : نجح', p_label;
END;
$$;

-- القراءة السالبة الصحيحة: RLS تُخفي الصفوف ولا ترمي. نتحقق من أن الاستعلام
-- يُنفَّذ ويُرجع صفر صف.
CREATE OR REPLACE FUNCTION tests.expect_no_rows(p_label text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_n bigint;
BEGIN
    EXECUTE 'SELECT count(*) FROM (' || p_sql || ') t' INTO v_n;
    IF v_n = 0 THEN
        RAISE NOTICE 'PASS [%] : 0 صفوف (RLS أخفى السجل)', p_label;
    ELSE
        RAISE EXCEPTION 'FAIL [%] : رجع % صف — تسريب!', p_label, v_n;
    END IF;
END;
$$;

-- القراءة الإيجابية: لازم نرى السجل فعلاً، وإلا الاختبار لا يثبت شيئاً.
CREATE OR REPLACE FUNCTION tests.expect_rows(p_label text, p_sql text,
                                             p_min bigint DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_n bigint;
BEGIN
    EXECUTE 'SELECT count(*) FROM (' || p_sql || ') t' INTO v_n;
    IF v_n >= p_min THEN
        RAISE NOTICE 'PASS [%] : % صف (مرئي)', p_label, v_n;
    ELSE
        RAISE EXCEPTION 'FAIL [%] : رجع % صف، توقعنا >= %', p_label, v_n, p_min;
    END IF;
END;
$$;

-- RPC مقبولة: ترجع status ليس 'error'
CREATE OR REPLACE FUNCTION tests.expect_sync_ok(p_label text, p_records jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_res   jsonb := public.sync_records_batch(p_records);
    v_det   jsonb := v_res->'details'->0;
    v_status text := coalesce(v_det->>'status', 'null');
BEGIN
    IF v_status IN ('ok', 'skipped', 'conflict') THEN
        RAISE NOTICE 'PASS [%] : status=%', p_label, v_status;
    ELSE
        RAISE EXCEPTION 'FAIL [%] : status=% msg=%', p_label, v_status,
                        coalesce(v_det->>'message', '');
    END IF;
END;
$$;

-- RPC مرفوضة: ترجع status='error' مع AUTHORIZATION_DENIED. هذه هي الطريقة
-- الصحيحة لفحص الكتابة — sync_records_batch لا ترمي استثناءً.
CREATE OR REPLACE FUNCTION tests.expect_sync_denied(p_label text, p_records jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_res    jsonb := public.sync_records_batch(p_records);
    v_det    jsonb := v_res->'details'->0;
    v_status text := coalesce(v_det->>'status', 'null');
    v_msg    text := coalesce(v_det->>'message', '');
BEGIN
    IF v_status = 'error' AND position('AUTHORIZATION_DENIED' in v_msg) > 0 THEN
        RAISE NOTICE 'PASS [%] : %', p_label, v_msg;
    ELSE
        RAISE EXCEPTION 'FAIL [%] : status=% msg=% (توقعنا رفضاً صريحاً)',
                        p_label, v_status, v_msg;
    END IF;
END;
$$;

-- الدالة ترمي استثناءً حقيقياً (مثل pull_remote_changes عبر مزرعة أخرى)
CREATE OR REPLACE FUNCTION tests.expect_raises_denied(p_label text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        RAISE EXCEPTION 'FAIL [%] : نجح التنفيذ وتوقعنا رفضاً', p_label;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FAIL[%' THEN
            RAISE;                              -- خطأ الاختبار نفسه، لا رفض
        END IF;
        IF position('AUTHORIZATION_DENIED' in SQLERRM) > 0
           OR position('غير مصرح' in SQLERRM) > 0
           OR position('permission denied for' in SQLERRM) > 0
           OR position('violates row-level security' in SQLERRM) > 0
           OR position('row-level security' in SQLERRM) > 0 THEN
            RAISE NOTICE 'PASS [%] : مُنع — %', p_label, SQLERRM;
        ELSE
            RAISE EXCEPTION 'FAIL [%] : خطأ غير متوقع — %', p_label, SQLERRM;
        END IF;
    END;
END;
$$;

-- ============================================================================
-- P0-0) البيانات الأساسية — لازم تُزرع وإلا كل الفحوص السالبة تُمرّر بلا معنى
-- ============================================================================
-- بدون rows حقيقية، "لا تسريب" و"لا يوجد سجل" متطابقان. نزرع سجلاً لكل مزرعة
-- ثم نتحقق من رؤيته(+) وإخفائه(−) لنفس السجل.
--
-- نستخدم flocks للعزل لأنها لا تحمل is_global، أي عزلها farm_id بحت.
-- customers لها دلالة مختلفة تُختبر منفصلة في P0-2.
-- كما نلتقط معرّف قطيع أ لأن mortality.flock_id NOT NULL، فلا يمكن إنشاء
-- تسجيل without قطيع.
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.expect_ok('seed: قطيع في مزرعة أ',
    format('INSERT INTO flocks (id, farm_id, breed, start_date, initial_count, '
           'current_count, status, sections_count) VALUES '
           '(%L, %L, ''أ'', ''2026-09-04'', 100, 100, ''active'', 1)',
           '00000000-0000-0000-0000-0000000000a1',
           '00000000-0000-0000-0000-000000000001'));

SELECT tests.set_user('00000000-0000-0000-0000-00000000000c');
SELECT tests.expect_ok('seed: قطيع في مزرعة ب',
    format('INSERT INTO flocks (id, farm_id, breed, start_date, initial_count, '
           'current_count, status, sections_count) VALUES '
           '(%L, %L, ''ب'', ''2026-09-04'', 100, 100, ''active'', 1)',
           '00000000-0000-0000-0000-0000000000b1',
           '00000000-0000-0000-0000-000000000002'));

-- ============================================================================
-- P0-1) عزل المزارع على القراءة (RLS)
-- ============================================================================
-- Level 1 — الوصول المباشر. admin_a يرى مزرعته ولا يرى مزرعة ب.
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.expect_rows('admin_a يقرأ مزرعته',
    'SELECT * FROM flocks WHERE farm_id = ''00000000-0000-0000-0000-000000000001''');
SELECT tests.expect_no_rows('admin_a لا يقرأ مزرعة ب',
    'SELECT * FROM flocks WHERE farm_id = ''00000000-0000-0000-0000-000000000002''');

-- المقلوب: admin_b يرى مزرعته ولا يرى مزرعة أ
SELECT tests.set_user('00000000-0000-0000-0000-00000000000c');
SELECT tests.expect_rows('admin_b يقرأ مزرعته',
    'SELECT * FROM flocks WHERE farm_id = ''00000000-0000-0000-0000-000000000002''');
SELECT tests.expect_no_rows('admin_b لا يقرأ مزرعة أ',
    'SELECT * FROM flocks WHERE farm_id = ''00000000-0000-0000-0000-000000000001''');

-- العامل مقيّد بمزرعته أيضاً (له عضوية في أ فقط)
SELECT tests.set_user('00000000-0000-0000-0000-00000000000b');
SELECT tests.expect_rows('worker_a يقرأ مزرعته',
    'SELECT * FROM flocks WHERE farm_id = ''00000000-0000-0000-0000-000000000001''');
SELECT tests.expect_no_rows('worker_a لا يقرأ مزرعة ب',
    'SELECT * FROM flocks WHERE farm_id = ''00000000-0000-0000-0000-000000000002''');

-- system_admin يتجاوز العزل عمداً — يجب أن يرى المزرعتين
SELECT tests.set_user('00000000-0000-0000-0000-00000000000e');
SELECT tests.expect_rows('sysadmin يتجاوز العزل (بالتصميم)',
    'SELECT * FROM flocks WHERE farm_id = ''00000000-0000-0000-0000-000000000001''');
SELECT tests.expect_rows('sysadmin يرى المزرعتين',
    'SELECT * FROM flocks WHERE farm_id = ''00000000-0000-0000-0000-000000000002''');

-- Level 2 — pull_remote_changes ترمي استثناءً (سلوك مختلف عن RLS)
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.expect_ok('admin_a يسحب مزرعته',
    'SELECT * FROM public.pull_remote_changes(''00000000-0000-0000-0000-000000000001'', 0)');
SELECT tests.expect_raises_denied('admin_a لا يسحب مزرعة ب',
    'SELECT * FROM public.pull_remote_changes(''00000000-0000-0000-0000-000000000002'', 0)');

-- Level 3 — كتابة عبر RPC في مزرعة أخرى. sync_records_batch تُرجع status=error
-- ولا ترمي، فالفحص على status لا على الاستثناء.
SELECT tests.expect_sync_denied('admin_a لا يُدرج في مزرعة ب عبر RPC',
    format('[{"table_name":"mortality","record_id":"%s","operation":"insert",'
           '"operation_id":"t1-x","data":{"farm_id":"%s","flock_id":"%s",'
           '"section_no":1,"date":"2026-09-04","count":1,"reason":"unknown",'
           '"worker_id":"%s"}}]',
           gen_random_uuid()::text,
           '00000000-0000-0000-0000-000000000002',
           '00000000-0000-0000-0000-0000000000b1',
           '00000000-0000-0000-0000-00000000000c')::jsonb);

SELECT tests.expect_sync_ok('admin_a يُدرج في مزرعته عبر RPC',
    format('[{"table_name":"mortality","record_id":"%s","operation":"insert",'
           '"operation_id":"t1-a","data":{"farm_id":"%s","flock_id":"%s",'
           '"section_no":1,"date":"2026-09-04","count":1,"reason":"unknown",'
           '"worker_id":"%s"}}]',
           gen_random_uuid()::text,
           '00000000-0000-0000-0000-000000000001',
           '00000000-0000-0000-0000-0000000000a1',
           '00000000-0000-0000-0000-00000000000a')::jsonb);

-- ============================================================================
-- P0-2) دلالة is_global على customers — عمداً عبر المزارع
-- ============================================================================
-- customers_op_select = is_system_admin() OR is_global OR user_has_farm_access().
-- و trg_customers_scope_guard يجعل is_global = (الدور manager أو system_admin)
-- وقت الإدخال — أي أن عميل ينشئه أي مدير يصبح مرئياً لكل المزارع. هذا سلوك
-- مقصود (زبون عام مشترك بين المزارع) وليس تسريباً، لكنه مخالف لتوقّع "العزل
-- حسب farm_id" على هذا الجدول تحديداً.
--
-- الاختبار الثاني أدناه يثبّت هذه الدلالة صراحةً حتى لا يعتمد عليها أحد
-- افتراضاً في المستقبل.
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a'); -- manager
SELECT tests.expect_ok('admin_a ينشئ عميلاً',
    format('INSERT INTO customers (id, farm_id, name, phone) VALUES '
           '(gen_random_uuid(), %L, ''عميل عام من أ'', ''000'')',
           '00000000-0000-0000-0000-000000000001'));

SELECT tests.assert(
    'عميلُ manager يصبح is_global=true تلقائياً (customers_scope_guard)',
    (SELECT is_global FROM customers WHERE name = 'عميل عام من أ'),
    format('is_global=%s',
           coalesce((SELECT is_global::text FROM customers
                     WHERE name = 'عميل عام من أ'), 'no row'))
);

SELECT tests.set_user('00000000-0000-0000-0000-00000000000b'); -- worker
SELECT tests.expect_ok('worker_a ينشئ عميلاً',
    format('INSERT INTO customers (id, farm_id, name, phone) VALUES '
           '(gen_random_uuid(), %L, ''عميل خاص من أ'', ''000'')',
           '00000000-0000-0000-0000-000000000001'));

SELECT tests.assert(
    'عميلُ worker يبقى is_global=false',
    NOT (SELECT is_global FROM customers WHERE name = 'عميل خاص من أ'),
    format('is_global=%s',
           coalesce((SELECT is_global::text FROM customers
                     WHERE name = 'عميل خاص من أ'), 'no row'))
);

-- الكائن رآه: مدير مزرعة ب يرى زبون أ العام، ولا يرى زبون أ الخاص.
SELECT tests.set_user('00000000-0000-0000-0000-00000000000c'); -- admin_b
SELECT tests.expect_rows('admin_b يرى عميل أ العام (is_global)',
    'SELECT * FROM customers WHERE name = ''عميل عام من أ''');
SELECT tests.expect_no_rows('admin_b لا يرى عميل أ الخاص',
    'SELECT * FROM customers WHERE name = ''عميل خاص من أ''');

-- ============================================================================
-- P0-3) العامل ضد البيانات المالية
-- ============================================================================
SELECT tests.set_user('00000000-0000-0000-0000-00000000000b'); -- worker_a

-- ملاحظة: العامل يستطيع قراءة customers في مزرعته (policy op_select يسمح بـ
-- user_has_farm_access). الفحص القديم كان يتوقع منعه — وهو خطأ: العميل
-- يحتاج أسماء الزبائن لعملياته. الحماية الفعلية على payments/revenue.
SELECT tests.expect_no_rows('worker_a لا يقرأ payments (RLS)',
    'SELECT * FROM payments');
SELECT tests.expect_no_rows('worker_a لا يقرأ expenses (RLS)',
    'SELECT * FROM expenses');

-- الكتابة على المالية المرشّحة مرفوضة: sync_can_write = false ⇒ status=error.
-- ملاحظة: payments وexpenses وflocks ممنوعة عن العامل. أما revenue فمسموحة
-- عمداً لأن تسجيلها часть من عملية الإنتاج (مطابقة تسليم/بيع) — الحماية الفعلية
-- عليها في RLS (farm scope) لا في whitelist الدور.
SELECT tests.assert('sync_can_write يمنع العامل من payments',
    NOT public.sync_can_write('worker', 'payments'));
SELECT tests.assert('sync_can_write يمنع العامل من expenses',
    NOT public.sync_can_write('worker', 'expenses'));
SELECT tests.assert('sync_can_write يمنع العامل من flocks',
    NOT public.sync_can_write('worker', 'flocks'));
SELECT tests.assert('sync_can_write يمنع العامل من customers',
    NOT public.sync_can_write('worker', 'customers'));
SELECT tests.assert('sync_can_write يسمح للعامل بـ revenue (بالتصميم)',
    public.sync_can_write('worker', 'revenue'));
SELECT tests.assert('sync_can_write يسمح للمدير بالكتابة على revenue',
    public.sync_can_write('manager', 'revenue'));
SELECT tests.assert('sync_can_write يسمح للمدير بالكتابة على payments',
    public.sync_can_write('manager', 'payments'));

SELECT tests.expect_sync_denied('worker_a لا يكتب payments عبر RPC',
    format('[{"table_name":"payments","record_id":"%s","operation":"insert",'
           '"operation_id":"t2-a","data":{"farm_id":"%s","customer_id":null,'
           '"date":"2026-09-04","price_per_carton":50,"total_due":100,'
           '"amount_paid":100,"payment_method":"cash",'
           '"manager_id":"00000000-0000-0000-0000-00000000000a"}}]',
           gen_random_uuid()::text, '00000000-0000-0000-0000-000000000001')::jsonb);

SELECT tests.expect_sync_denied('worker_a لا يكتب flocks (غير مسموح)',
    format('[{"table_name":"flocks","record_id":"%s","operation":"insert",'
           '"operation_id":"t2-b","data":{"farm_id":"%s","breed":"x",'
           '"start_date":"2026-09-04","initial_count":10,"current_count":10,'
           '"status":"active","sections_count":1}}]',
           gen_random_uuid()::text, '00000000-0000-0000-0000-000000000001')::jsonb);

SELECT tests.expect_raises_denied('worker_a لا يسحب مزرعة ب',
    'SELECT * FROM public.pull_remote_changes(''00000000-0000-0000-0000-000000000002'', 0)');
SELECT tests.expect_ok('worker_a يسحب مزرعته (مسموح ضمن عضويته)',
    'SELECT * FROM public.pull_remote_changes(''00000000-0000-0000-0000-000000000001'', 0)');

-- ============================================================================
-- P0-4) المزامنة تحت الفشل — idempotency (لا تكرار)
-- ============================================================================
-- الإرسال بنفس operation_id مرتين لا يُنتج صفَّي sync_changes. إعادة الإرسال
-- تُرجع details بلا 'status' و skipped=1 — أي "عُدّت سابقاً"، لا خطأ.
DO $$
DECLARE
    v_rec   uuid := '00000000-0000-0000-0000-0000000000dd';
    v_batch jsonb;
    v_n     bigint;
    v_rows  bigint;
    v_res   jsonb;
BEGIN
    PERFORM tests.set_user('00000000-0000-0000-0000-00000000000a');
    v_batch := jsonb_build_array(jsonb_build_object(
        'table_name', 'feed_consumption', 'record_id', v_rec::text,
        'operation', 'insert', 'operation_id', 'idem-1',
        'previous_version', NULL,
        'data', jsonb_build_object(
            'farm_id', '00000000-0000-0000-0000-000000000001',
            'date', '2026-09-04', 'entry_mode', 'bags', 'bags_count', 10,
            'quantity_kg', 240, 'worker_id',
            '00000000-0000-0000-0000-00000000000a')
    ));

    v_res := public.sync_records_batch(v_batch);
    PERFORM tests.assert(
        'إدراج أول: status=ok',
        v_res->'details'->0->>'status' = 'ok',
        coalesce('status=' || coalesce(v_res->'details'->0->>'status', 'null'), '')
    );

    -- إعادة الإرسال بنفس operation_id
    v_res := public.sync_records_batch(v_batch);
    PERFORM tests.assert(
        'إعادة الإرسال: skipped (لا معالجة ثانية)',
        (v_res->>'skipped')::int = 1 AND (v_res->>'affected')::int = 0,
        format('skipped=%s affected=%s',
               coalesce(v_res->>'skipped', '?'), coalesce(v_res->>'affected', '?'))
    );

    SELECT count(*) INTO v_rows FROM sync_changes WHERE record_id = v_rec;
    PERFORM tests.assert(
        'إعادة الإرسال لا تُكرّر صف sync_changes',
        v_rows = 1,
        format('عدد الصفوف=%s (توقعنا 1)', v_rows)
    );

    SELECT count(*) INTO v_n FROM feed_consumption WHERE id = v_rec;
    PERFORM tests.assert(
        'إعادة الإرسال لا تُكرّر السجل الأصلي',
        v_n = 1,
        format('عدد السجلات=%s (توقعنا 1)', v_n)
    );
END $$;

-- ============================================================================
-- P0-5) التعارضات (OCC) داخل المزرعة نفسها
-- ============================================================================
-- سيناريو: جهاز A يعدّل ثم جهاز B (نفس المزرعة) يعدّل بنفس previous_version
-- القديم. الخادم يقارن previous_version مع version الحالي ويكتشف التعارض.
-- sync_records_batch لا ترمي استثناءً — تُرجع status='conflict'.
DO $$
DECLARE
    v_rec  uuid := '00000000-0000-0000-0000-0000000000ee';
    v_ver  bigint;
    v_res  jsonb;
BEGIN
    -- 1) admin_a ينشئ السجل (version = 1)
    PERFORM tests.set_user('00000000-0000-0000-0000-00000000000a');
    v_res := public.sync_records_batch(jsonb_build_array(jsonb_build_object(
        'table_name', 'flocks', 'record_id', v_rec::text,
        'operation', 'insert', 'operation_id', 't4-seed',
        'previous_version', NULL,
        'data', jsonb_build_object(
            'farm_id', '00000000-0000-0000-0000-000000000001',
            'breed', 'أصلي', 'start_date', '2026-09-04',
            'initial_count', 100, 'current_count', 100,
            'status', 'active', 'sections_count', 1)
    )));
    PERFORM tests.assert(
        'إنشاء السجل: status=ok',
        v_res->'details'->0->>'status' = 'ok',
        coalesce('status=' || coalesce(v_res->'details'->0->>'status', 'null') ||
                 ' msg=' || coalesce(v_res->'details'->0->>'message', ''), '')
    );

    SELECT version INTO v_ver FROM flocks WHERE id = v_rec;
    PERFORM tests.assert('السجل يبدأ بـ version=1', v_ver = 1,
                         format('version=%s', v_ver));

    -- 2) الجهاز A يعدّل بـ previous_version=1 ⇒ ينجح، version→2
    v_res := public.sync_records_batch(jsonb_build_array(jsonb_build_object(
        'table_name', 'flocks', 'record_id', v_rec::text,
        'operation', 'update', 'operation_id', 't4-A', 'previous_version', 1,
        'data', jsonb_build_object('current_count', 95)
    )));
    PERFORM tests.assert(
        'جهاز A: update بـ previous_version=1 ينجح',
        v_res->'details'->0->>'status' = 'ok',
        coalesce('status=' || coalesce(v_res->'details'->0->>'status', 'null') ||
                 ' msg=' || coalesce(v_res->'details'->0->>'message', ''), '')
    );
    SELECT version INTO v_ver FROM flocks WHERE id = v_rec;
    PERFORM tests.assert('بعد تعديل A: version=2', v_ver = 2,
                         format('version=%s', v_ver));

    -- 3) الجهاز B يعدّل بنفس previous_version=1 (متقادم) ⇒ conflict
    --    نفس المزرعة (admin_a) لكن عملية مختلفة، كما يحدث مع جهازين.
    v_res := public.sync_records_batch(jsonb_build_array(jsonb_build_object(
        'table_name', 'flocks', 'record_id', v_rec::text,
        'operation', 'update', 'operation_id', 't4-B', 'previous_version', 1,
        'data', jsonb_build_object('current_count', 90)
    )));
    PERFORM tests.assert(
        'جهاز B: previous_version متقادم ⇒ conflict',
        v_res->'details'->0->>'status' = 'conflict',
        coalesce('status=' || coalesce(v_res->'details'->0->>'status', 'null') ||
                 ' msg=' || coalesce(v_res->'details'->0->>'message', ''), '')
    );

    -- 4) الـ conflict ما طُبِّقش على السجل
    PERFORM tests.assert(
        'تعارض B لم يطمس تعديل A',
        (SELECT current_count FROM flocks WHERE id = v_rec) = 95,
        format('current_count=%s (توقعنا 95)',
               coalesce((SELECT current_count FROM flocks WHERE id = v_rec)::text, 'null'))
    );

    -- 5) الجهاز B يحدّث بـ previous_version الصحيح ⇒ ينجح
    v_res := public.sync_records_batch(jsonb_build_array(jsonb_build_object(
        'table_name', 'flocks', 'record_id', v_rec::text,
        'operation', 'update', 'operation_id', 't4-B2', 'previous_version', 2,
        'data', jsonb_build_object('current_count', 90)
    )));
    PERFORM tests.assert(
        'جهاز B: إعادة المزامنة بـ previous_version=2 تنجح',
        v_res->'details'->0->>'status' = 'ok',
        coalesce('status=' || coalesce(v_res->'details'->0->>'status', 'null') ||
                 ' msg=' || coalesce(v_res->'details'->0->>'message', ''), '')
    );
END $$;

-- ============================================================================
-- P0-6) التعارض عبر المزارع
-- ============================================================================
-- admin_b لا يستطيع تعديل سجل في مزرعة أ حتى لو أرسل previous_version صحيح.
-- هذا هو الفارق بين "تعارض تقني" و"تسريب عبر المزارع": الأول status=conflict
-- (السجل سليم)، والثاني AUTHORIZATION_DENIED (لم يُكتب شيء أصلاً).
SELECT tests.set_user('00000000-0000-0000-0000-00000000000c');
SELECT tests.expect_sync_denied('admin_b لا يعدّل سجل مزرعة أ',
    jsonb_build_array(jsonb_build_object(
        'table_name', 'flocks',
        'record_id', '00000000-0000-0000-0000-0000000000ee',
        'operation', 'update',
        'operation_id', 't6-B',
        'previous_version', 3,
        'data', jsonb_build_object('current_count', 50)
    )));

-- والتأكد أن الرفض لم يترك أثراً جزئياً على السجل. الفحص لازم يتم بصَ-eye
-- صاحب المزرعة، فـ admin_b لا يرى السجل أصلاً (RLS) — قراءة "no row" عنده
-- لا تعني المحو ولا تعني السلامة.
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.assert(
    'رفض admin_b لم يغيّر current_count',
    (SELECT current_count FROM flocks WHERE id = '00000000-0000-0000-0000-0000000000ee') = 90,
    format('current_count=%s (توقعنا 90 من آخر تعديل ناجح)',
           coalesce((SELECT current_count::text FROM flocks
                     WHERE id = '00000000-0000-0000-0000-0000000000ee'), 'no row'))
);

-- ============================================================================
-- P0-7) الحذف يُنتج tombstone (لا يختفي السجل من الأجهزة الأخرى)
-- ============================================================================
DO $$
DECLARE
    v_rec  uuid := '00000000-0000-0000-0000-0000000000ff';
    v_res  jsonb;
    v_tomb bigint;
BEGIN
    PERFORM tests.set_user('00000000-0000-0000-0000-00000000000a');
    v_res := public.sync_records_batch(jsonb_build_array(jsonb_build_object(
        'table_name', 'flocks', 'record_id', v_rec::text,
        'operation', 'insert', 'operation_id', 't6-a', 'previous_version', NULL,
        'data', jsonb_build_object(
            'farm_id', '00000000-0000-0000-0000-000000000001',
            'breed', 'للحذف', 'start_date', '2026-09-04',
            'initial_count', 5, 'current_count', 5,
            'status', 'active', 'sections_count', 1)
    )));
    PERFORM tests.assert('إنشاء سجل للحذف',
                         v_res->'details'->0->>'status' = 'ok');

    v_res := public.sync_records_batch(jsonb_build_array(jsonb_build_object(
        'table_name', 'flocks', 'record_id', v_rec::text,
        'operation', 'delete', 'operation_id', 't6-d', 'previous_version', NULL
    )));
    PERFORM tests.assert(
        'الحذف عبر sync يُبلَّغ ok',
        v_res->'details'->0->>'status' = 'ok',
        coalesce('status=' || coalesce(v_res->'details'->0->>'status', 'null') ||
                 ' msg=' || coalesce(v_res->'details'->0->>'message', ''), '')
    );

    -- السجل يبقى soft-deleted حتى لا تختفي السجلات من أجهزة أخرى
    PERFORM tests.assert(
        'السجل المحذوف يبقى soft-deleted (deleted_at) لا محذوفاً نهائياً',
        (SELECT deleted_at IS NOT NULL FROM flocks WHERE id = v_rec),
        format('rows=%s',
               coalesce((SELECT count(*) FROM flocks WHERE id = v_rec)::text, 'null'))
    );

    SELECT count(*) INTO v_tomb FROM sync_changes
    WHERE record_id = v_rec AND table_name = 'flocks';
    PERFORM tests.assert(
        'الحذف يُبثّ إلى sync_changes (tombstone)',
        v_tomb >= 2,
        format('عدد تغييرات السجل=%s (توقعنا insert+delete)', v_tomb)
    );
END $$;

-- ============================================================================
-- STEP 9) النتيجة
-- ============================================================================
DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'انتهت اختبارات P0 — كل الفحوص أعلاه PASS';
    RAISE NOTICE 'ROLLBACK — لا تغيير دائم على القاعدة';
    RAISE NOTICE '========================================';
END $$;

ROLLBACK;