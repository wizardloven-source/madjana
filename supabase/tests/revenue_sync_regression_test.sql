-- ============================================================================
-- اختبار انحدار — إصلاح 20260926000100 (نشر الإيرادات + حماية فقدان التعديلات)
-- ============================================================================
-- للتحقق من كل بند أصلحته الترقية 20260926000100.
--
-- طريقة التشغيل: Supabase SQL Editor على نسخة **Stage** بعد تطبيق الترقية.
-- كل شيء داخل BEGIN/ROLLBACK ⇒ لا تغيير دائم.
-- ⚠️ بدّل المعرّفات في STEP 0 (نفس تنبيه p0_isolation_and_sync_test.sql).
--
-- كل اختبار يطبع PASS/FAIL عبر RAISE NOTICE. راجعMessages بعد التشغيل.
-- ============================================================================

BEGIN;

-- ── STEP 0) المعرّفات ────────────────────────────────────────────────────
DO $$
DECLARE
    v_admin_a  uuid := '00000000-0000-0000-0000-00000000000a';
    v_worker_a uuid := '00000000-0000-0000-0000-00000000000b';
    v_farm_a   uuid := '00000000-0000-0000-0000-000000000001';
    v_farm_b   uuid := '00000000-0000-0000-0000-000000000002';
BEGIN
    IF v_admin_a = v_farm_a OR v_farm_a = v_farm_b THEN
        RAISE EXCEPTION 'التكوين غير مكتمل: بدّل المعرّفات في STEP 0';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS tests;

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

CREATE OR REPLACE FUNCTION tests.assert(p_label text, p_cond boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_cond THEN
        RAISE NOTICE 'PASS [%] %', p_label, p_detail;
    ELSE
        RAISE EXCEPTION 'FAIL [%] %', p_label, p_detail;
    END IF;
END;
$$;

-- ── اختبار 1: revenue داخل قوائم المزامنة ─────────────────────────────
-- الفحص الحاسم: revenue مسموح بالكتابة/القراءة حسب الدور. كانت false
-- ⇒ كل عملية إيراد تُرفض عند الرفع.
SELECT tests.assert(
    'revenue مسموح بالكتابة للمدير',
    public.sync_can_write('manager', 'revenue'),
    'كان false في القوائم السابقة'
);

SELECT tests.assert(
    'revenue مسموح بالقراءة للمدير',
    public.sync_can_read('manager', 'revenue')
);

SELECT tests.assert(
    'revenue مسموح بالقراءة للعامل',
    public.sync_can_read('worker', 'revenue')
);

-- sync_live_ids يجب أن يذكر revenue كمفتاح (مصالحة الحذف تعتمد ذلك)
SELECT tests.assert(
    'sync_live_ids تُرجع revenue',
    public.sync_live_ids('00000000-0000-0000-0000-000000000001') ? 'revenue',
    'مفتاح revenue مفقود ⇒ لا مصالحة حذف للإيرادات'
);

-- ── اختبار 2: الأعمدة المفقودة استُعيدت ─────────────────────────────────
DO $$
DECLARE
    v_flock     uuid := gen_random_uuid();
    v_farm      uuid := '00000000-0000-0000-0000-000000000001';
    v_res       jsonb;
    v_detail    jsonb;
    v_customer  uuid := gen_random_uuid();
    v_cust_res  jsonb;
    v_cust_det  jsonb;
BEGIN
    PERFORM tests.set_user('00000000-0000-0000-0000-00000000000a');

    -- 2أ) current_count كان مفقوداً من قائمة أعمدة flocks ⇒ تعديل العدّ الحيّ
    --      كان يُبلَّغ نجاحاً ولا يصل الخادم إطلاقاً.
    v_res := public.sync_records_batch(
        jsonb_build_array(jsonb_build_object(
            'table_name', 'flocks', 'operation', 'insert',
            'operation_id', gen_random_uuid()::text,
            'record_id', v_flock::text,
            'data', jsonb_build_object(
                'breed', 'اختبار', 'start_date', CURRENT_DATE::text,
                'initial_count', 100, 'current_count', 97,
                'status', 'active', 'sections_count', 1
            ),
            'previous_version', NULL
        )),
        'regression-test-device'
    );

    v_detail := v_res->'details'->0;
    SELECT tests.assert(
        'flocks.current_count يصل الخادم',
        v_detail->>'status' = 'ok',
        coalesce('status=' || coalesce(v_detail->>'status', 'null') ||
                 ' msg=' || coalesce(v_detail->>'message', ''), '')
    );

    IF v_detail->>'status' = 'ok' THEN
        PERFORM tests.assert(
            'flocks.current_count مخزَّن فعلاً بقيمة 97',
            (SELECT current_count FROM flocks WHERE id = v_flock) = 97
        );
    END IF;

    -- 2ب) is_global كان مفقوداً من قائمة أعمدة customers ⇒ الزبون العام
    --      المنشأ على جهاز لا يصل الخادم ⇒ يختفي من المزارع الأخرى.
    v_cust_res := public.sync_records_batch(
        jsonb_build_array(jsonb_build_object(
            'table_name', 'customers', 'operation', 'insert',
            'operation_id', gen_random_uuid()::text,
            'record_id', v_customer::text,
            'data', jsonb_build_object(
                'name', 'زبون عام اختبار', 'phone', '000', 'is_global', true
            ),
            'previous_version', NULL
        )),
        'regression-test-device'
    );

    v_cust_det := v_cust_res->'details'->0;
    SELECT tests.assert(
        'customers.is_global يصل الخادم',
        v_cust_det->>'status' = 'ok',
        coalesce('status=' || coalesce(v_cust_det->>'status', 'null') ||
                 ' msg=' || coalesce(v_cust_det->>'message', ''), '')
    );

    IF v_cust_det->>'status' = 'ok' THEN
        PERFORM tests.assert(
            'customers.is_global مخزَّن فعلاً true',
            (SELECT is_global FROM customers WHERE id = v_customer) IS TRUE
        );
    END IF;
END $$;

-- ── اختبار 3: INSERT على سجل موجود يجب أن يُبثّ (لا CONTINUE مبكر) ───────
-- هذا هو الفارق بين «مُزامن» و«فقد صامت». الكود القديم كان يُرجع ok
-- ويخرج قبل INSERT INTO sync_changes ⇒ تعديلات القطعان لا تُبثّ لأجهزة أخرى.
DO $$
DECLARE
    v_flock   uuid := gen_random_uuid();
    v_farm    uuid := '00000000-0000-0000-0000-000000000001';
    v_res     jsonb;
    v_before  bigint;
    v_after   bigint;
    v_detail  jsonb;
BEGIN
    PERFORM tests.set_user('00000000-0000-0000-0000-00000000000a');

    -- السجل أُدخل مسبقاً عبر REST (كما يحدث فعلياً في الكود الحالي)
    INSERT INTO flocks (id, farm_id, breed, start_date, initial_count,
                        current_count, status, sections_count, version)
    VALUES (v_flock, v_farm, 'سابق', CURRENT_DATE, 100, 100, 'active', 1, 1);

    SELECT count(*) INTO v_before
    FROM sync_changes
    WHERE record_id = v_flock;

    -- الآن يأتي عبر الطابور بنفس الـ id (المسار الفعلي من العميل)
    v_res := public.sync_records_batch(
        jsonb_build_array(jsonb_build_object(
            'table_name', 'flocks', 'operation', 'insert',
            'operation_id', gen_random_uuid()::text,
            'record_id', v_flock::text,
            'data', jsonb_build_object(
                'breed', 'سابق', 'start_date', CURRENT_DATE::text,
                'initial_count', 100, 'current_count', 88,
                'status', 'active', 'sections_count', 1
            ),
            'previous_version', NULL
        )),
        'regression-test-device'
    );

    SELECT count(*) INTO v_after
    FROM sync_changes
    WHERE record_id = v_flock;

    v_detail := v_res->'details'->0;
    SELECT tests.assert(
        'سجل موجود مسبقاً: العملية تُبلَّغ ok',
        v_detail->>'status' = 'ok'
    );

    -- هذا هو الفحص الحاسم: هل وُلد صف sync_changes رغم أن السجل كان موجوداً؟
    SELECT tests.assert(
        'سجل موجود مسبقاً: يُبثّ إلى sync_changes (إصلاح الفقد الصامت)',
        v_after > v_before,
        format('عدد تغييرات هذا السجل: قبل=%s بعد=%s', v_before, v_after)
    );

    SELECT tests.assert(
        'سجل موجود مسبقاً: التعديل طُبِّق فعلاً (upsert لا تجاهل)',
        (SELECT current_count FROM flocks WHERE id = v_flock) = 88
    );
END $$;

-- ── اختبار 4: previous_version NULL لا يُنتج تعارضاً وهمياً ─────────────
-- الكود القديم: version = NULL لا يطابق أي صف ⇒ ROW_COUNT=0 ⇒ «تعارض»
-- في كل عملية لا تمرّر previous_version، أي أن التعديلات تضيع بصمت.
DO $$
DECLARE
    v_cust  uuid := gen_random_uuid();
    v_farm  uuid := '00000000-0000-0000-0000-000000000001';
    v_res   jsonb;
    v_det   jsonb;
BEGIN
    PERFORM tests.set_user('00000000-0000-0000-0000-00000000000a');

    INSERT INTO customers (id, farm_id, name, phone, version, deleted_at)
    VALUES (v_cust, v_farm, 'قبل', '111', 1, NULL);

    v_res := public.sync_records_batch(
        jsonb_build_array(jsonb_build_object(
            'table_name', 'customers', 'operation', 'update',
            'operation_id', gen_random_uuid()::text,
            'record_id', v_cust::text,
            'data', jsonb_build_object('name', 'بعد'),
            'previous_version', NULL
        )),
        'regression-test-device'
    );

    v_det := v_res->'details'->0;
    SELECT tests.assert(
        'previous_version=NULL لا يُنتج تعارضاً وهمياً',
        v_det->>'status' <> 'conflict',
        coalesce('status=' || coalesce(v_det->>'status', 'null') ||
                 ' msg=' || coalesce(v_det->>'message', ''), '')
    );

    SELECT tests.assert(
        'previous_version=NULL: التحديث طُبِّق فعلاً',
        (SELECT name FROM customers WHERE id = v_cust) = 'بعد'
    );
END $$;

-- ── اختبار 5: تفاصيل الرد تحمل operation_id ───────────────────────────
-- بدونها يعتمد العميل على ترتيب FIFO داخل record_id، وهو مضلّل عندما
-- يحمل السجل أكثر من عملية في نفس الدفعة.
DO $$
DECLARE
    v_op  text := gen_random_uuid()::text;
    v_res jsonb;
BEGIN
    PERFORM tests.set_user('00000000-0000-0000-0000-00000000000a');

    v_res := public.sync_records_batch(
        jsonb_build_array(jsonb_build_object(
            'table_name', 'customers', 'operation', 'insert',
            'operation_id', v_op,
            'record_id', gen_random_uuid()::text,
            'data', jsonb_build_object('name', 'اختبار operation_id', 'phone', '2'),
            'previous_version', NULL
        )),
        'regression-test-device'
    );

    SELECT tests.assert(
        'الرد يحمل operation_id للعميل',
        v_res->'details'->0->>'operation_id' = v_op,
        coalesce('operation_id=' || coalesce(v_res->'details'->0->>'operation_id', 'null'), '')
    );
END $$;

-- ── اختبار 6: العامل لا يستطيع تجاوز الفصل المالي عبر REST ────────────
-- price_per_kg ممنوع على العامل داخل sync_records_batch. نفحص التفعيل.
SELECT tests.assert(
    'sync_can_read يمنع العامل من قراءة payments',
    NOT public.sync_can_read('worker', 'payments'),
    'الكشف المالي للمدير فقط'
);

SELECT tests.assert(
    'sync_can_write يمنع العامل من الكتابة على expenses',
    NOT public.sync_can_write('worker', 'expenses')
);

SELECT tests.assert(
    'sync_can_write يسمح للمدير بالكتابة على revenue',
    public.sync_can_write('manager', 'revenue')
);

-- ── اختبار 7: عزل المزارع ما زال سارياً بعد التعديل ───────────────────
-- إعادة تعريف sync_can_read/sync_can_write/pull_remote_changes لا يجوز أن
-- تفتح تسريباً بين المزارع.
DO $$
DECLARE
    v_leak int;
BEGIN
    PERFORM tests.set_user('00000000-0000-0000-0000-00000000000a'); -- admin_a
    BEGIN
        SELECT count(*) INTO v_leak
        FROM public.pull_remote_changes(0, 200, '00000000-0000-0000-0000-000000000002');
        SELECT tests.assert(
            'admin_a لا يستطيع سحب تغييرات مزرعة ب',
            false,
            format('سحب %s صفاً من مزرعة أخرى — تسريب!', v_leak)
        );
    EXCEPTION WHEN OTHERS THEN
        IF position('AUTHORIZATION_DENIED' in SQLERRM) > 0 THEN
            RAISE NOTICE 'PASS [admin_a لا يستطيع سحب تغييرات مزرعة ب] مُنع بشكل صحيح';
        ELSE
            RAISE EXCEPTION 'FAIL [عزل المزارع] خطأ غير متوقع: %', SQLERRM;
        END IF;
    END;
END $$;

-- ── STEP 8) النتيجة ───────────────────────────────────────────────────
DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'انتهى اختبار الانحدار 20260926000100';
    RAISE NOTICE 'ROLLBACK — لا تغيير دائم على القاعدة';
    RAISE NOTICE '========================================';
END $$;

ROLLBACK;
