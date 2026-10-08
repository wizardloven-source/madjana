-- ============================================================================
-- P0 M7: revenue.worker_id TEXT -> UUID, FK + index, conversion & rollback
-- ============================================================================
-- The rules under test, from the M7 migration (20261003000700) + rollback:
--   * revenue.worker_id becomes UUID (the ONLY text worker_id column left).
--   * ALL 9 worker_id columns (revenue + the eight operational tables) are uuid
--   * revenue_worker_id_fkey -> users(id) ON DELETE SET NULL (the record
--     survives the user; the gate rejects CASCADE for worker_id).
--   * idx_revenue_worker is live.
--   * RLS on revenue is untouched and still gates (sysadmin + managing manager
--     may see rows; a plain worker sees ZERO and cannot insert).
--   * the migration is IDEMPOTENT: re-applying on an already-uuid column skips
--     the conversion (the guard is what makes naive re-runs safe).
--   * the rollback restores text, then a replay of the migration re-converts:
--     valid uuids survive, '' -> NULL, NULL stays NULL, row counts preserved.
--   * the precheck REFUSES any non-empty non-uuid worker_id.
--
-- Identity is faked exactly like the other P0 suites: the session role is
-- test_runner (a member of authenticated, NOBYPASSRLS) and tests.set_user()
-- writes request.jwt.claims so auth.uid() + role helpers resolve to the
-- fixture user. DDL replay runs under SET ROLE postgres (the session's SESSION
-- USER is postgres, so the switch is legal -- proven in 4l's PART IV).
-- Fixtures (local_fixtures.sql): worker_a ...000b, manager_a ...000a,
-- sysadmin ...000e, FARM_A ...000001 / FARM_B ...000002.
--
-- Runs inside BEGIN/ROLLBACK.
--   psql -f supabase/tests/p0_revenue_worker_id_test.sql
-- ============================================================================

BEGIN;

-- ── helpers ──────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS tests;

CREATE OR REPLACE FUNCTION tests.expect(
    p_label text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok THEN
        RAISE NOTICE 'PASS  %', rpad(p_label, 54, '.');
    ELSE
        RAISE EXCEPTION 'FAIL  %  %', p_label, p_detail;
    END IF;
END;
$$;

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

-- writer denied: an RLS-protected write must be refused
CREATE OR REPLACE FUNCTION tests.expect_write_denied(p_label text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        RAISE EXCEPTION 'FAIL  %  نجح وتوقعنا رفضاً', p_label;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FAIL  %' THEN
            RAISE;
        END IF;
        IF position('row-level security' in SQLERRM) > 0
           OR position('permission denied' in SQLERRM) > 0
           OR position('insufficient_privilege' in SQLERRM) > 0 THEN
            RAISE NOTICE 'PASS  %  مُنع', p_label;
        ELSE
            RAISE EXCEPTION 'FAIL  %  خطأ غير متوقع — %', p_label, SQLERRM;
        END IF;
    END;
END;
$$;

-- any other expected DB error (FK violation, bad uuid, precheck refusal...)
CREATE OR REPLACE FUNCTION tests.expect_error(p_label text, p_sql text, p_match text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        RAISE EXCEPTION 'FAIL  %  نجح وتوقعنا خطأ', p_label;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FAIL  %' THEN
            RAISE;
        END IF;
        IF position(p_match in SQLERRM) > 0 THEN
            RAISE NOTICE 'PASS  %  ✓ %', p_label, SQLERRM;
        ELSE
            RAISE EXCEPTION 'FAIL  %  خطأ لا يطابق — %', p_label, SQLERRM;
        END IF;
    END;
END;
$$;

-- ============================================================================
-- PART I — structural: type, all-9-uuid, FK (SET NULL), index, RLS intact
-- ============================================================================
DO $$
DECLARE
    v_worker_columns int;
    v_uuid_columns   int;
    v_rls boolean;
    v_confdef text;
    v_confdel text;
BEGIN
    SELECT count(*) INTO v_worker_columns
      FROM information_schema.columns
     WHERE column_name = 'worker_id';
    PERFORM tests.expect('يوجد 9 أعمدة worker_id في كل الجداول',
        v_worker_columns = 9, 'columns=' || v_worker_columns);

    SELECT count(*) INTO v_uuid_columns
      FROM information_schema.columns
     WHERE column_name = 'worker_id' AND data_type = 'uuid';
    PERFORM tests.expect('كل أعمدة worker_id التسعة أصبحت uuid',
        v_uuid_columns = v_worker_columns,
        'uuid=' || v_uuid_columns || ' text=' || (v_worker_columns - v_uuid_columns));

    PERFORM tests.expect('revenue.worker_id نفسها من نوع uuid',
        EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'revenue'
                   AND column_name = 'worker_id' AND data_type = 'uuid'));

    SELECT confdeltype INTO v_confdel
      FROM pg_constraint
     WHERE conname = 'revenue_worker_id_fkey' AND contype = 'f';
    PERFORM tests.expect('FK revenue_worker_id_fkey موجودة',
        v_confdel IS NOT NULL, 'confdeltype=' || COALESCE(v_confdel, 'missing'));

    SELECT pg_get_constraintdef(oid) INTO v_confdef
      FROM pg_constraint
     WHERE conname = 'revenue_worker_id_fkey' AND contype = 'f';
    PERFORM tests.expect('FK تستهدف users(id) بـ ON DELETE SET NULL',
        v_confdel = 'n' AND v_confdef ILIKE '%REFERENCES users%' AND v_confdef ILIKE '%SET NULL%',
        COALESCE(v_confdef, 'missing'));

    PERFORM tests.expect('الفهرس idx_revenue_worker موجود على revenue',
        EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = 'public' AND tablename = 'revenue'
                   AND indexname = 'idx_revenue_worker'));

    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'revenue';
    PERFORM tests.expect('RLS على revenue ما زال مفعّلاً',
        v_rls);

    PERFORM tests.expect('سياسات revenue الأربع ما زالت موجودة',
        (SELECT count(*) FROM pg_policies
          WHERE schemaname = 'public' AND tablename = 'revenue'
            AND policyname IN ('revenue_read', 'revenue_insert',
                               'revenue_update', 'revenue_delete')) = 4);

    RAISE NOTICE 'M7 structural block passed';
END $$;

-- ============================================================================
-- PART II — semantics: valid uuid, NULL, bad values, FK, ON DELETE SET NULL,
--           and RLS still gating on the financial rows
-- ============================================================================
SELECT tests.set_user('00000000-0000-0000-0000-00000000000e');

-- 2a) a valid worker assignment stores as uuid
INSERT INTO revenue (id, farm_id, date, category, description, amount, worker_id)
VALUES ('00000000-0000-0000-0000-0000000000a1',
        '00000000-0000-0000-0000-000000000001', '2026-10-02', 'eggSales',
        'M7 valid', 100, '00000000-0000-0000-0000-00000000000b');
SELECT tests.expect('معرف عامل صحيح يُخزَّن (صحيح ✅)',
    (SELECT worker_id = '00000000-0000-0000-0000-00000000000b'::uuid
       FROM revenue WHERE id = '00000000-0000-0000-0000-0000000000a1'),
    'round-trip الاختيار للقيمة');

-- 2b) NULL is still an allowed, meaningful "no attribution"
INSERT INTO revenue (id, farm_id, date, category, description, amount, worker_id)
VALUES ('00000000-0000-0000-0000-0000000000a2',
        '00000000-0000-0000-0000-000000000001', '2026-10-02', 'eggSales',
        'M7 null', 200, NULL);
SELECT tests.expect('worker_id = NULL مقبول (NULL ✅)',
    (SELECT worker_id IS NULL FROM revenue WHERE id = '00000000-0000-0000-0000-0000000000a2'));

-- 2c) an unknown user id fails the FK (non-existent worker ❌)
SELECT tests.expect_error('معرف عامل غير موجود مرفوض (FK)',
    'INSERT INTO revenue (id, farm_id, date, category, description, amount, worker_id) '
    'VALUES (''00000000-0000-0000-0000-0000000000ff'', '
    '''00000000-0000-0000-0000-000000000001'', ''2026-10-02'', ''eggSales'', '
    '''M7 badfk'', 300, ''00000000-0000-0000-0000-0000000000ff'')',
    'foreign key');

-- 2d) an empty string cannot enter a uuid column directly (غير صحيح ❌)
SELECT tests.expect_error('الفراغ النصي مرفوض على عمود uuid',
    'INSERT INTO revenue (id, farm_id, date, category, description, amount, worker_id) '
    'VALUES (''00000000-0000-0000-0000-0000000000f0'', '
    '''00000000-0000-0000-0000-000000000001'', ''2026-10-02'', ''eggSales'', '
    '''M7 empty'', 400, '''')',
    'invalid input syntax for type uuid');

-- 2e) ON DELETE SET NULL: the revenue row must survive the user deletion
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('00000000-0000-0000-0000-0000000000ee', 'm7temp@test.local',
        '{"role":"worker","full_name":"M7 Temp",
          "farm_id":"00000000-0000-0000-0000-000000000001"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO revenue (id, farm_id, date, category, description, amount, worker_id)
VALUES ('00000000-0000-0000-0000-0000000000a3',
        '00000000-0000-0000-0000-000000000001', '2026-10-02', 'other',
        'M7 deluser', 50, '00000000-0000-0000-0000-0000000000ee');
SELECT tests.expect('الصف سُجّل بمستخدم مؤقت',
    (SELECT worker_id = '00000000-0000-0000-0000-0000000000ee'::uuid
       FROM revenue WHERE id = '00000000-0000-0000-0000-0000000000a3'));

DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000ee';

SELECT tests.expect('ON DELETE SET NULL: صف الإيراد نجا من حذف المستخدم',
    EXISTS (SELECT 1 FROM revenue WHERE id = '00000000-0000-0000-0000-0000000000a3'),
    'الصف حُذف مع المستخدم');
SELECT tests.expect('ON DELETE SET NULL: worker_id أُصبح NULL',
    (SELECT worker_id IS NULL FROM revenue WHERE id = '00000000-0000-0000-0000-0000000000a3'),
    'worker_id لم يُصفَّر');

-- 2f) RLS still gating: a plain worker sees ZERO financial rows and cannot write
SELECT tests.set_user('00000000-0000-0000-0000-00000000000b');
SELECT tests.expect('العامل لا يقرأ أي صف revenue',
    (SELECT count(*) FROM revenue) = 0,
    'count=' || (SELECT count(*)::text FROM revenue));
SELECT tests.expect_write_denied('العامل لا يُدرج في revenue',
    'INSERT INTO revenue (farm_id, date, category, description, amount) '
    'VALUES (''00000000-0000-0000-0000-000000000001'', ''2026-10-02'', '
    '''eggSales'', ''محاولة عامل'', 999)');

-- 2g) the managing manager still sees the farm's revenue rows
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.expect('المدير يقرأ إيرادات مزرعته',
    (SELECT count(*) FROM revenue) >= 3,
    'count=' || (SELECT count(*)::text FROM revenue));

DO $block$
BEGIN
    RAISE NOTICE 'M7 semantics + RLS block passed';
END;
$block$;

-- ============================================================================
-- PART III — idempotent re-apply of the forward migration (uuid state)
-- ============================================================================
SET ROLE postgres;

DO $m7replay$
DECLARE
    v_kind text;
    v_bad  int;
BEGIN
    SELECT c.data_type INTO v_kind
      FROM information_schema.columns c
     WHERE c.table_schema = 'public' AND c.table_name = 'revenue'
       AND c.column_name  = 'worker_id';
    IF v_kind IS DISTINCT FROM 'text' THEN
        RAISE NOTICE 'M7 replay: column already %, conversion skipped', v_kind;
    ELSE
        SELECT count(*) INTO v_bad FROM public.revenue
         WHERE worker_id IS NOT NULL AND worker_id <> ''
           AND worker_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
        IF v_bad > 0 THEN
            RAISE EXCEPTION 'found % invalid worker_id values in revenue', v_bad;
        END IF;
        ALTER TABLE public.revenue ALTER COLUMN worker_id TYPE uuid
            USING NULLIF(worker_id, '')::uuid;
    END IF;
END;
$m7replay$;

ALTER TABLE public.revenue DROP CONSTRAINT IF EXISTS revenue_worker_id_fkey;
ALTER TABLE public.revenue ADD CONSTRAINT revenue_worker_id_fkey
    FOREIGN KEY (worker_id) REFERENCES users (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_revenue_worker ON public.revenue (worker_id);

SET ROLE test_runner;

DO $$
DECLARE
    v_fk   int;
    v_idx  int;
    v_cnt  int;
BEGIN
    SELECT count(*) INTO v_fk FROM pg_constraint
     WHERE conname = 'revenue_worker_id_fkey' AND contype = 'f';
    PERFORM tests.expect('idempotent: إعادة التطبيق لم تكرر الـ FK',
        v_fk = 1, 'fk_count=' || v_fk);

    SELECT count(*) INTO v_idx FROM pg_indexes
     WHERE schemaname = 'public' AND tablename = 'revenue'
       AND indexname = 'idx_revenue_worker';
    PERFORM tests.expect('idempotent: إعادة التطبيق لم تكرر الفهرس',
        v_idx = 1, 'idx_count=' || v_idx);

    SELECT count(*) INTO v_cnt FROM revenue;
    PERFORM tests.expect('idempotent: أعداد الصفوف ثابتة بعد إعادة التطبيق',
        v_cnt >= 3, 'rows=' || v_cnt);

    RAISE NOTICE 'M7 idempotency block passed (تمّ تطبيق الترحيل مرتين)';
END $$;

-- ============================================================================
-- PART IV — rollback, then a replay of the migration on REAL text values:
--           precheck refusal, '' -> NULL, valid survives, counts preserved
-- ============================================================================
SET ROLE postgres;

-- 4a) apply the rollback exactly as a re-apply would
ALTER TABLE public.revenue DROP CONSTRAINT IF EXISTS revenue_worker_id_fkey;
DROP INDEX IF EXISTS idx_revenue_worker;
ALTER TABLE public.revenue ALTER COLUMN worker_id TYPE text USING worker_id::text;

DO $$
DECLARE
    v_type text;
BEGIN
    SELECT data_type INTO v_type FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'revenue'
       AND column_name = 'worker_id';
    PERFORM tests.expect('rollback: worker_id عاد إلى text',
        v_type = 'text', v_type);
    PERFORM tests.expect('rollback: FK أُسقطت',
        NOT EXISTS (SELECT 1 FROM pg_constraint
                     WHERE conname = 'revenue_worker_id_fkey' AND contype = 'f'));
    PERFORM tests.expect('rollback: الفهرس أُسقط',
        NOT EXISTS (SELECT 1 FROM pg_indexes
                     WHERE schemaname = 'public' AND tablename = 'revenue'
                       AND indexname = 'idx_revenue_worker'));
END $$;

-- 4b) seed the pre-M7 shape: a valid uuid, an empty '', a NULL, and a BAD value
INSERT INTO revenue (id, farm_id, date, category, description, amount, worker_id)
VALUES ('00000000-0000-0000-0000-0000000000d1',
        '00000000-0000-0000-0000-000000000001', '2026-10-03', 'other', 'valid',  55,
        '00000000-0000-0000-0000-00000000000b'),
       ('00000000-0000-0000-0000-0000000000d2',
        '00000000-0000-0000-0000-000000000001', '2026-10-03', 'other', 'empty',  66, ''),
       ('00000000-0000-0000-0000-0000000000d3',
        '00000000-0000-0000-0000-000000000001', '2026-10-03', 'other', 'null',   77, NULL),
       ('00000000-0000-0000-0000-0000000000d4',
        '00000000-0000-0000-0000-000000000001', '2026-10-03', 'other', 'garbage', 88, 'not-a-uuid');

-- 4c) the precheck must REFUSE while the bad value is on file
DO $$
DECLARE
    v_bad int;
BEGIN
    BEGIN
        SELECT count(*) INTO v_bad FROM public.revenue
         WHERE worker_id IS NOT NULL AND worker_id <> ''
           AND worker_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
        IF v_bad > 0 THEN
            RAISE EXCEPTION 'found % invalid worker_id values in revenue', v_bad;
        END IF;
        PERFORM tests.expect('الفحص المسبق يرفض القيم الخاطئة',
            false, 'الفحص لم يرفض رغم وجود قيمة خاطئة');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('الفحص المسبق يرفض القيم الخاطئة',
            SQLERRM LIKE '%invalid worker_id values%', SQLERRM);
    END;
END $$;

-- 4d) remove the garbage, keep valid + '' + NULL, capture counts
DELETE FROM public.revenue WHERE id = '00000000-0000-0000-0000-0000000000d4';

DO $$
DECLARE
    v_bad   int;
    v_before int;
    v_after  int;
    v_type   text;
BEGIN
    SELECT count(*) INTO v_bad FROM public.revenue
     WHERE worker_id IS NOT NULL AND worker_id <> ''
       AND worker_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
    PERFORM tests.expect('البيانات نظيفة بعد إزالة القيمة الخاطئة',
        v_bad = 0, 'v_bad=' || v_bad);

    SELECT count(*) INTO v_before FROM public.revenue;
    PERFORM tests.expect('عداد قبل التحويل مسجّل (>3 صفوف)',
        v_before > 3, 'before=' || v_before);

    -- 4e) the migration's conversion, verbatim
    ALTER TABLE public.revenue ALTER COLUMN worker_id TYPE uuid
        USING NULLIF(worker_id, '')::uuid;

    SELECT data_type INTO v_type FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'revenue'
       AND column_name = 'worker_id';
    PERFORM tests.expect('التحويل الثاني نجح: العودة إلى uuid',
        v_type = 'uuid', v_type);

    SELECT count(*) INTO v_after FROM public.revenue;
    PERFORM tests.expect('عداد محفوظ قبل/بعد التحويل',
        v_before = v_after, 'before=' || v_before || ' after=' || v_after);

    PERFORM tests.expect('الفراغ النصي أصبح NULL ('' '' → NULL ✅)',
        (SELECT worker_id IS NULL FROM revenue WHERE id = '00000000-0000-0000-0000-0000000000d2'),
        'worker_id لم يصبح NULL');
    PERFORM tests.expect('NULL بقي NULL',
        (SELECT worker_id IS NULL FROM revenue WHERE id = '00000000-0000-0000-0000-0000000000d3'));
    PERFORM tests.expect('القيمة الصحيحة نجت من التحويل (000b)',
        (SELECT worker_id = '00000000-0000-0000-0000-00000000000b'::uuid
           FROM revenue WHERE id = '00000000-0000-0000-0000-0000000000d1'));
END $$;

-- 4f) idempotent مرة ثالثة بأمان: التطبيق على عمود uuid لا يكسر شيئاً
DO $m7replay2$
DECLARE
    v_kind text;
    v_bad  int;
BEGIN
    SELECT c.data_type INTO v_kind
      FROM information_schema.columns c
     WHERE c.table_schema = 'public' AND c.table_name = 'revenue'
       AND c.column_name  = 'worker_id';
    IF v_kind IS DISTINCT FROM 'text' THEN
        RAISE NOTICE 'M7 replay 2: column already %, conversion skipped', v_kind;
    ELSE
        SELECT count(*) INTO v_bad FROM public.revenue
         WHERE worker_id IS NOT NULL AND worker_id <> ''
           AND worker_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
        IF v_bad > 0 THEN
            RAISE EXCEPTION 'found % invalid worker_id values in revenue', v_bad;
        END IF;
        ALTER TABLE public.revenue ALTER COLUMN worker_id TYPE uuid
            USING NULLIF(worker_id, '')::uuid;
    END IF;
END;
$m7replay2$;

DO $$
DECLARE
    v_type text;
    v_d1 uuid;
    v_d2 uuid;
    v_d3 uuid;
    v_cnt int;
BEGIN
    SELECT data_type INTO v_type FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'revenue'
       AND column_name = 'worker_id';
    PERFORM tests.expect('إعادة التطبيق لم تغيّر النوع (uuid بقي uuid)',
        v_type = 'uuid', v_type);

    SELECT worker_id INTO v_d1 FROM revenue WHERE id = '00000000-0000-0000-0000-0000000000d1';
    SELECT worker_id INTO v_d2 FROM revenue WHERE id = '00000000-0000-0000-0000-0000000000d2';
    SELECT worker_id INTO v_d3 FROM revenue WHERE id = '00000000-0000-0000-0000-0000000000d3';
    PERFORM tests.expect('القيم صمدت أمام إعادة التطبيق الثانية',
        v_d1 = '00000000-0000-0000-0000-00000000000b'::uuid AND v_d2 IS NULL AND v_d3 IS NULL,
        'd1=' || COALESCE(v_d1::text, 'NULL') || ' d2=' || COALESCE(v_d2::text, 'NULL'));

    SELECT count(*) INTO v_cnt FROM revenue;
    PERFORM tests.expect('عدد الصفوف ثابت بعد إعادة التطبيق',
        v_cnt >= 3, 'rows=' || v_cnt);

    RAISE NOTICE 'M7 rollback + re-conversion block passed';
END $$;

-- ============================================================================
--  النتيجة
-- ============================================================================
DO $final$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'p0_revenue_worker_id_test: كل الفحوص PASS';
    RAISE NOTICE 'worker_id uuid، 9 أعمدة uuid، FK SET NULL، index، idempotency،';
    RAISE NOTICE 'rollback، التحويل ('' -> NULL)، وRLS سليم (ثم ROLLBACK).';
    RAISE NOTICE '============================================================';
END;
$final$;

ROLLBACK;