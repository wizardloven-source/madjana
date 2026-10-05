-- ============================================================================
--  p0_financial_rls_guard_test.sql
--  حارس دائم ضد ثغرة تصعيد الصلاحيات على الجداول المالية.
-- ============================================================================
--
--  PURPOSE
--  -------
--  p0_isolation_and_sync_test.sql proved farm isolation on OPERATIONAL tables
--  (flocks and friends). It never proved that a worker is blocked from the
--  MONEY. docs/TEST_COVERAGE_GAPS.md calls this out as the missing T3, and
--  that gap is precisely what let migration 20260926000800 weaken the
--  financial policies without any test failing.
--
--  This file closes the gap. It is the test that must FAIL before
--  20261002000000_restore_financial_rls.sql and PASS after it.
--
--  HOW TO RUN
--  ----------
--    MUST run as a NON-SUPERUSER (test_runner), exactly like every other suite
--    in run_all.py. The schema has no FORCE ROW LEVEL SECURITY anywhere, so as
--    `postgres` every policy is bypassed and this file passes vacuously --
--    the single most dangerous way to run it.
--
--      psql -h 127.0.0.1 -p 5433 -U postgres -d madjana_test \
--           -v ON_ERROR_STOP=1 \
--           -c "SET ROLE test_runner" \
--           -f p0_financial_rls_guard_test.sql
--
--  Fixtures required: tests/local_fixtures.sql (committed by build_test_db.py)
--      manager A ...000a    worker A ...000b    farm A ...0001
--      manager B ...000c    worker B ...000d    farm B ...0002
--      sysadmin  ...000e
--
--  Everything runs inside BEGIN/ROLLBACK, so it is safe on a scratch database
--  and leaves production untouched.
-- ============================================================================

BEGIN;

-- ============================================================================
--  Harness — self-contained, so this file can also run standalone.
--  Contracts match the helpers in p0_isolation_and_sync_test.sql.
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS tests;

-- request.jwt.claims is what auth.uid() reads, so this is what makes
-- auth.uid() resolve to p_uid for every RLS predicate in the schema.
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

-- SELECT denial under RLS is silent: rows disappear, nothing raises. Zero rows
-- IS the correct denial, so the only way to prove the block is to assert it.
CREATE OR REPLACE FUNCTION tests.expect_no_rows(p_label text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_n bigint;
BEGIN
    EXECUTE 'SELECT count(*) FROM (' || p_sql || ') t' INTO v_n;
    IF v_n = 0 THEN
        RAISE NOTICE 'PASS [%] : 0 صفوف (RLS أخفى السجل)', p_label;
    ELSE
        RAISE EXCEPTION 'FAIL [%] : رجع % صف — تسريب!', p_label, v_n;
    END IF;
END;
$$;

-- The positive counterpart. Without it the negative assertions prove nothing:
-- a test that sees zero rows because the table is empty is not a pass.
CREATE OR REPLACE FUNCTION tests.expect_rows(p_label text, p_sql text,
                                             p_min bigint DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_n bigint;
BEGIN
    EXECUTE 'SELECT count(*) FROM (' || p_sql || ') t' INTO v_n;
    IF v_n >= p_min THEN
        RAISE NOTICE 'PASS [%] : % صف (مرئي)', p_label, v_n;
    ELSE
        RAISE EXCEPTION 'FAIL [%] : رجع % صف، توقعنا >= %', p_label, v_n, p_min;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION tests.expect_ok(p_label text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RAISE NOTICE 'PASS [%] : نجح', p_label;
END;
$$;

-- Writes are refused by raising, and the message names the reason.
-- ONLY valid for INSERT, which evaluates WITH CHECK unconditionally.
CREATE OR REPLACE FUNCTION tests.expect_write_denied(p_label text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        RAISE EXCEPTION 'FAIL [%] : نجح وتوقعنا رفضاً', p_label;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FAIL[%' THEN
            RAISE;                                      -- re-raise the assert
        END IF;
        IF position('row-level security' in SQLERRM) > 0
           OR position('permission denied' in SQLERRM) > 0
           OR position('insufficient_privilege' in SQLERRM) > 0 THEN
            RAISE NOTICE 'PASS [%] : مُنع — %', p_label, left(SQLERRM, 90);
        ELSE
            RAISE EXCEPTION 'FAIL [%] : خطأ غير متوقع — %', p_label, SQLERRM;
        END IF;
    END;
END;
$$;

-- UPDATE and DELETE are DENIED DIFFERENTLY, and getting this wrong silently
-- produces a test that fails against correct code.
--
-- RLS filters candidate rows through USING. A worker cannot see the row, so
-- the UPDATE/DELETE matches ZERO rows and returns success — it does NOT raise
-- "row-level security", because WITH CHECK is never reached for a row that
-- was never selected. Asserting an exception here would report a false FAIL on
-- a correctly secured database.
--
-- So for UPDATE/DELETE the statement must run WITHOUT raising, and the row must
-- be provably unchanged when read back with sufficient privilege (see the
-- no-writes and farm-b-untouched state blocks). This helper asserts the
-- first half only.
CREATE OR REPLACE FUNCTION tests.expect_silent(p_label text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION
            'FAIL [%] : رمي استثناء (%). إن كان هذا RLS على UPDATE/DELETE ف|Note أن '
            'UPDATE/DELETE الممنوع لا يرمي أصلاً — تحقق أن Policy الحقيقية USING.',
            p_label, left(SQLERRM, 120);
    END;
    RAISE NOTICE 'PASS [%] : صامت بلا استثناء', p_label;
END;
$$;

-- ============================================================================
--  STEP 0) Preconditions — a test that cannot fail proves nothing
-- ============================================================================
DO $step0$
DECLARE
    v_manager_a uuid := '00000000-0000-0000-0000-00000000000a';
    v_worker_a  uuid := '00000000-0000-0000-0000-00000000000b';
    v_manager_b uuid := '00000000-0000-0000-0000-00000000000c';
    v_farm_a    uuid := '00000000-0000-0000-0000-000000000001';
    v_farm_b    uuid := '00000000-0000-0000-0000-000000000002';
    v_role  text;
    v_super boolean;
    v_bypass boolean;
BEGIN
    -- 0a. The running role must not bypass RLS, or everything below is theatre.
    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass
      FROM pg_roles WHERE rolname = current_user;
    IF v_super OR v_bypass THEN
        RAISE EXCEPTION
            'ABORT: current_user (%) هو superuser أو BYPASSRLS — النتائج ستكون '
            'كاذبة. شغّل هذا الملف كـ test_runner.', current_user;
    END IF;
    RAISE NOTICE 'STEP0: current_user=% super=% bypassrls=%',
                 current_user, v_super, v_bypass;

    -- 0b. Roles resolve as the fixtures claim.
    PERFORM tests.set_user(v_worker_a);
    v_role := current_user_role();
    PERFORM tests.assert('STEP0 دور العامل يُقرأ صحيحاً', v_role = 'worker',
                         format('role=%s', v_role));

    PERFORM tests.set_user(v_manager_a);
    v_role := current_user_role();
    PERFORM tests.assert('STEP0 دور المدير يُقرأ صحيحاً', v_role = 'manager',
                         format('role=%s', v_role));

    -- 0c. THE decisive precondition. If access and manages disagree here, the
    --     helpers the policies depend on are not the ones we assume, and every
    --     assertion below would be meaningless.
    PERFORM tests.set_user(v_worker_a);
    PERFORM tests.assert('STEP0 العامل عضو بالمزرعة (access = TRUE)',
                         user_has_farm_access(v_farm_a), '');
    PERFORM tests.assert('STEP0 العامل ليس مديراً (manages = FALSE)',
                         NOT user_manages_farm(v_farm_a), '');
    PERFORM tests.assert('STEP0 العامل لا يصل مزرعة أخرى (access = FALSE)',
                         NOT user_has_farm_access(v_farm_b), '');

    PERFORM tests.set_user(v_manager_a);
    PERFORM tests.assert('STEP0 المدير يدير مزرعته (manages = TRUE)',
                         user_manages_farm(v_farm_a), '');
    PERFORM tests.assert('STEP0 المدير لا يدير مزرعة أخرى (manages = FALSE)',
                         NOT user_manages_farm(v_farm_b), '');
END;
$step0$;

-- ============================================================================
--  STEP 1) زرع صفوف حقيقية — لكل مزرعة
--
--  Without real rows, "no rows visible" and "row hidden" are indistinguishable.
--  Seeds are written as each farm's own manager, which works both before and
--  after the fix (managers may write in either state).
-- ============================================================================
-- ── FARM_A ────────────────────────────────────────────────────────────────
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.expect_ok('seed: قطيع في مزرعة أ',
    'INSERT INTO flocks (id, farm_id, breed, start_date, initial_count, '
    'current_count, status, sections_count) VALUES '
    '(''00000000-0000-0000-0000-0000000000a1'', '
    '''00000000-0000-0000-0000-000000000001'', ''أ'', ''2026-10-01'', 100, 100, '
    '''active'', 1)');
SELECT tests.expect_ok('seed: زبون في مزرعة أ',
    'INSERT INTO customers (id, farm_id, name, phone) VALUES '
    '(''00000000-0000-0000-0000-0000000000a2'', '
    '''00000000-0000-0000-0000-000000000001'', ''زبون أ'', ''0000'')');
SELECT tests.expect_ok('seed: دفعة في مزرعة أ',
    'INSERT INTO payments (id, farm_id, customer_id, date, price_per_carton, '
    'total_due, amount_paid, payment_method, manager_id) VALUES '
    '(''00000000-0000-0000-0000-0000000000a3'', '
    '''00000000-0000-0000-0000-000000000001'', '
    '''00000000-0000-0000-0000-0000000000a2'', ''2026-10-01'', 1, 100, 100, '
    '''cash'', ''00000000-0000-0000-0000-00000000000a'')');
SELECT tests.expect_ok('seed: مصروف في مزرعة أ',
    'INSERT INTO expenses (id, farm_id, date, category, description, amount) '
    'VALUES (''00000000-0000-0000-0000-0000000000a4'', '
    '''00000000-0000-0000-0000-000000000001'', ''2026-10-01'', ''other'', '
    '''مصروف أ'', 50)');
SELECT tests.expect_ok('seed: إيراد في مزرعة أ',
    'INSERT INTO revenue (id, farm_id, date, category, description, amount) '
    'VALUES (''00000000-0000-0000-0000-0000000000a5'', '
    '''00000000-0000-0000-0000-000000000001'', ''2026-10-01'', ''other'', '
    '''إيراد أ'', 70)');
SELECT tests.expect_ok('seed: رصيد افتتاحي في مزرعة أ',
    'INSERT INTO opening_balances (id, farm_id, flock_id, eggs_produced) '
    'VALUES (''00000000-0000-0000-0000-0000000000a6'', '
    '''00000000-0000-0000-0000-000000000001'', '
    '''00000000-0000-0000-0000-0000000000a1'', 500)');
SELECT tests.expect_ok('seed: صنف مخزون في مزرعة أ',
    'INSERT INTO inventory_items (id, farm_id, name, unit, quantity) VALUES '
    '(''00000000-0000-0000-0000-0000000000a7'', '
    '''00000000-0000-0000-0000-000000000001'', ''علف'', ''bag'', 10)');
SELECT tests.expect_ok('seed: تعديل مخزون في مزرعة أ',
    'INSERT INTO stock_adjustments (id, farm_id, stock_type, delta_qty, date, '
    'manager_id) VALUES (''00000000-0000-0000-0000-0000000000a8'', '
    '''00000000-0000-0000-0000-000000000001'', ''eggs'', 5, ''2026-10-01'', '
    '''00000000-0000-0000-0000-00000000000a'')');

-- ── FARM_B ────────────────────────────────────────────────────────────────
SELECT tests.set_user('00000000-0000-0000-0000-00000000000c');
SELECT tests.expect_ok('seed: قطيع في مزرعة ب',
    'INSERT INTO flocks (id, farm_id, breed, start_date, initial_count, '
    'current_count, status, sections_count) VALUES '
    '(''00000000-0000-0000-0000-0000000000b1'', '
    '''00000000-0000-0000-0000-000000000002'', ''ب'', ''2026-10-01'', 100, 100, '
    '''active'', 1)');
SELECT tests.expect_ok('seed: زبون في مزرعة ب',
    'INSERT INTO customers (id, farm_id, name, phone) VALUES '
    '(''00000000-0000-0000-0000-0000000000b2'', '
    '''00000000-0000-0000-0000-000000000002'', ''زبون ب'', ''0001'')');
SELECT tests.expect_ok('seed: دفعة في مزرعة ب',
    'INSERT INTO payments (id, farm_id, customer_id, date, price_per_carton, '
    'total_due, amount_paid, payment_method, manager_id) VALUES '
    '(''00000000-0000-0000-0000-0000000000b3'', '
    '''00000000-0000-0000-0000-000000000002'', '
    '''00000000-0000-0000-0000-0000000000b2'', ''2026-10-01'', 2, 200, 200, '
    '''cash'', ''00000000-0000-0000-0000-00000000000c'')');
SELECT tests.expect_ok('seed: مصروف في مزرعة ب',
    'INSERT INTO expenses (id, farm_id, date, category, description, amount) '
    'VALUES (''00000000-0000-0000-0000-0000000000b4'', '
    '''00000000-0000-0000-0000-000000000002'', ''2026-10-01'', ''other'', '
    '''مصروف ب'', 60)');

-- Count as sysadmin: the last set_user above was manager_b, who can only see
-- farm B's single payment, so asserting "2 payments" as manager_b would fail.
SELECT tests.set_user('00000000-0000-0000-0000-00000000000e');
DO $seed_check$
BEGIN
    PERFORM tests.assert('STEP1 زُرع صف مالي في كل مزرعة',
        (SELECT count(*) FROM payments) = 2,
        format('payments=% expenses=% revenue=% opening_balances=% inventory=% adj=%',
               (SELECT count(*) FROM payments),
               (SELECT count(*) FROM expenses),
               (SELECT count(*) FROM revenue),
               (SELECT count(*) FROM opening_balances),
               (SELECT count(*) FROM inventory_items),
               (SELECT count(*) FROM stock_adjustments)));
END;
$seed_check$;

-- ============================================================================
--  STEP 2) العامل لا يستطيع قراءة المال  —  المتطلب ①
-- ============================================================================
SELECT tests.set_user('00000000-0000-0000-0000-00000000000b');
SELECT tests.expect_no_rows('worker_a لا يقرأ payments في مزرعته',
    'SELECT * FROM payments');
SELECT tests.expect_no_rows('worker_a لا يقرأ expenses في مزرعته',
    'SELECT * FROM expenses');
SELECT tests.expect_no_rows('worker_a لا يقرأ revenue',
    'SELECT * FROM revenue');
SELECT tests.expect_no_rows('worker_a لا يقرأ opening_balances',
    'SELECT * FROM opening_balances');
SELECT tests.expect_no_rows('worker_a لا يقرأ inventory_items',
    'SELECT * FROM inventory_items');
SELECT tests.expect_no_rows('worker_a لا يقرأ stock_adjustments',
    'SELECT * FROM stock_adjustments');
SELECT tests.expect_no_rows('worker_a لا يقرأ payments لمزرعة أخرى',
    'SELECT * FROM payments WHERE farm_id = ''00000000-0000-0000-0000-000000000002''');

-- ============================================================================
--  STEP 3) العامل لا يستطيع كتابة المال  —  المتطلب ②
--  This is the branch the P0 actually exploited: REST POST /expenses.
-- ============================================================================
SELECT tests.set_user('00000000-0000-0000-0000-00000000000b');
SELECT tests.expect_write_denied('worker_a لا يُدرج في expenses',
    'INSERT INTO expenses (farm_id, date, category, description, amount) '
    'VALUES (''00000000-0000-0000-0000-000000000001'', ''2026-10-02'', '
    '''other'', ''محاولة عامل'', 999)');
SELECT tests.expect_write_denied('worker_a لا يُدرج في payments',
    'INSERT INTO payments (farm_id, customer_id, date, price_per_carton, '
    'total_due, amount_paid, payment_method, manager_id) VALUES '
    '(''00000000-0000-0000-0000-000000000001'', '
    '''00000000-0000-0000-0000-0000000000a2'', ''2026-10-02'', 1, 999, 999, '
    '''cash'', ''00000000-0000-0000-0000-00000000000b'')');
-- UPDATE/DELETE must NOT raise (RLS hides the row, so 0 rows are touched) and
-- must leave the row intact — the proof of "intact" is the $no_writes$ state
-- block below, which reads back with sufficient privilege.
SELECT tests.expect_silent('worker_a تحاول تحديث expenses (يجب ألا ترمي)',
    'UPDATE expenses SET amount = 1 '
    'WHERE id = ''00000000-0000-0000-0000-0000000000a4''');
SELECT tests.expect_silent('worker_a تحاول تحديث payments (يجب ألا ترمي)',
    'UPDATE payments SET amount_paid = 1 '
    'WHERE id = ''00000000-0000-0000-0000-0000000000a3''');
SELECT tests.expect_silent('worker_a تحاول حذف expenses (يجب ألا ترمي)',
    'DELETE FROM expenses WHERE id = ''00000000-0000-0000-0000-0000000000a4''');
SELECT tests.expect_write_denied('worker_a لا يُدرج في inventory_items',
    'INSERT INTO inventory_items (farm_id, name, unit, quantity) VALUES '
    '(''00000000-0000-0000-0000-000000000001'', ''سم'', ''piece'', 1)');
SELECT tests.expect_write_denied('worker_a لا يُدرج في stock_adjustments',
    'INSERT INTO stock_adjustments (farm_id, stock_type, delta_qty, date, '
    'manager_id) VALUES (''00000000-0000-0000-0000-000000000001'', '
    '''eggs'', 100, ''2026-10-02'', ''00000000-0000-0000-0000-00000000000b'')');
-- The label says worker_b, so actually switch to worker_b: worker_a is not a
-- member of farm B at all, so both workers get denied here for different
-- reasons and only one of them exercises the intended path.
SELECT tests.set_user('00000000-0000-0000-0000-00000000000d');
SELECT tests.expect_write_denied('worker_b لا يُدرج في expenses بمزرعة ب',
    'INSERT INTO expenses (farm_id, date, category, description, amount) '
    'VALUES (''00000000-0000-0000-0000-000000000002'', ''2026-10-02'', '
    '''other'', ''محاولة عامل ب'', 999)');

-- Nothing above should have landed.
--
-- This block MUST read back as sysadmin, not as the worker. As worker_a these
-- counts are 0 — not 2 — because RLS is doing exactly what it should, so
-- asserting them as the worker would fail against a correct database.
SELECT tests.set_user('00000000-0000-0000-0000-00000000000e');
DO $no_writes$
BEGIN
    PERFORM tests.assert('عامل لم يُدرج دفعة جديدة (لا دمج ولا حذف)',
        (SELECT count(*) FROM payments) = 2,
        format('payments=%', (SELECT count(*) FROM payments)));
    PERFORM tests.assert('العامل لم يُدرج مصروفاً في أي مزرعة',
        (SELECT count(*) FROM expenses) = 2,
        format('expenses=%', (SELECT count(*) FROM expenses)));
    PERFORM tests.assert('العامل لم يُدرج صنف مخزون',
        (SELECT count(*) FROM inventory_items) = 1,
        format('inventory=%', (SELECT count(*) FROM inventory_items)));
    PERFORM tests.assert('دفعة مزرعة أ لم تُعدَّل',
        (SELECT amount_paid FROM payments
          WHERE id = '00000000-0000-0000-0000-0000000000a3') = 100,
        format('amount_paid=%',
               (SELECT amount_paid FROM payments
                WHERE id = '00000000-0000-0000-0000-0000000000a3')));
    PERFORM tests.assert('مصروف مزرعة أ لم يُحذف',
        (SELECT amount FROM expenses
          WHERE id = '00000000-0000-0000-0000-0000000000a4') = 50,
        format('amount=%',
               (SELECT amount FROM expenses
                WHERE id = '00000000-0000-0000-0000-0000000000a4')));
END;
$no_writes$;

-- ============================================================================
--  STEP 4) المدير يستطيع كل شيء داخل مزرعته  —  المتطلب ③
--  Without these positive checks, STEP 2 and STEP 3 would also pass against a
--  database where nobody can read any money at all.
-- ============================================================================
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.expect_rows('manager_a يقرأ payments مزرعته',
    'SELECT * FROM payments WHERE farm_id = ''00000000-0000-0000-0000-000000000001''');
SELECT tests.expect_rows('manager_a يقرأ expenses مزرعته',
    'SELECT * FROM expenses WHERE farm_id = ''00000000-0000-0000-0000-000000000001''');
SELECT tests.expect_rows('manager_a يقرأ revenue مزرعته',
    'SELECT * FROM revenue WHERE farm_id = ''00000000-0000-0000-0000-000000000001''');
SELECT tests.expect_rows('manager_a يقرأ opening_balances مزرعته',
    'SELECT * FROM opening_balances WHERE farm_id = ''00000000-0000-0000-0000-000000000001''');
SELECT tests.expect_rows('manager_a يقرأ inventory_items مزرعته',
    'SELECT * FROM inventory_items WHERE farm_id = ''00000000-0000-0000-0000-000000000001''');
SELECT tests.expect_rows('manager_a يقرأ stock_adjustments مزرعته',
    'SELECT * FROM stock_adjustments WHERE farm_id = ''00000000-0000-0000-0000-000000000001''');

SELECT tests.expect_ok('manager_a يُدرج في expenses',
    'INSERT INTO expenses (farm_id, date, category, description, amount) '
    'VALUES (''00000000-0000-0000-0000-000000000001'', ''2026-10-02'', '
    '''other'', ''مصروف مدير'', 25)');
SELECT tests.expect_ok('manager_a يُدرج في revenue',
    'INSERT INTO revenue (farm_id, date, category, description, amount) '
    'VALUES (''00000000-0000-0000-0000-000000000001'', ''2026-10-02'', '
    '''other'', ''إيراد مدير'', 35)');
SELECT tests.expect_ok('manager_a يُحدّث دفعة مزرعته',
    'UPDATE payments SET amount_paid = 60 '
    'WHERE id = ''00000000-0000-0000-0000-0000000000a3''');
SELECT tests.expect_ok('manager_a يُدرج في inventory_items',
    'INSERT INTO inventory_items (farm_id, name, unit, quantity) VALUES '
    '(''00000000-0000-0000-0000-000000000001'', ''جهاز'', ''piece'', 2)');
SELECT tests.expect_ok('manager_a يُدرج في stock_adjustments',
    'INSERT INTO stock_adjustments (farm_id, stock_type, delta_qty, date, '
    'manager_id) VALUES (''00000000-0000-0000-0000-000000000001'', '
    '''cartons'', 3, ''2026-10-02'', ''00000000-0000-0000-0000-00000000000a'')');

-- ============================================================================
--  STEP 5) المدير لا يستطيع على مزرعة أخرى  —  المتطلب ④
--  This is the farm-scoping half of the predicate: user_manages_farm(farm_id)
--  must reject the other farm even though the caller IS a manager.
-- ============================================================================
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.expect_no_rows('manager_a لا يقرأ payments مزرعة ب',
    'SELECT * FROM payments WHERE farm_id = ''00000000-0000-0000-0000-000000000002''');
SELECT tests.expect_no_rows('manager_a لا يقرأ expenses مزرعة ب',
    'SELECT * FROM expenses WHERE farm_id = ''00000000-0000-0000-0000-000000000002''');
SELECT tests.expect_write_denied('manager_a لا يُدرج في expenses بمزرعة ب',
    'INSERT INTO expenses (farm_id, date, category, description, amount) '
    'VALUES (''00000000-0000-0000-0000-000000000002'', ''2026-10-02'', '
    '''other'', ''تعدٍ على مزرعة ب'', 999)');
SELECT tests.expect_silent('manager_a تحاول تحديث دفعة بمزرعة ب (يجب ألا ترمي)',
    'UPDATE payments SET amount_paid = 1 '
    'WHERE id = ''00000000-0000-0000-0000-0000000000b3''');
SELECT tests.expect_silent('manager_a تحاول حذف مصروف بمزرعة ب (يجب ألا ترمي)',
    'DELETE FROM expenses WHERE id = ''00000000-0000-0000-0000-0000000000b4''');

-- Farm B's rows must be verified as sysadmin. As manager_a these reads return
-- NULL / 0 because manager_a cannot see farm B — which is the point of STEP 5,
-- but makes it useless as a state assertion.
SELECT tests.set_user('00000000-0000-0000-0000-00000000000e');
DO $b_untouched$
BEGIN
    PERFORM tests.assert('دفعة مزرعة ب لم تُعدَّل',
        (SELECT amount_paid FROM payments
          WHERE id = '00000000-0000-0000-0000-0000000000b3') = 200,
        format('amount_paid=%',
               (SELECT amount_paid FROM payments
                WHERE id = '00000000-0000-0000-0000-0000000000b3')));
    PERFORM tests.assert('مصروف مزرعة ب لم يُحذف',
        (SELECT amount FROM expenses
          WHERE id = '00000000-0000-0000-0000-0000000000b4') = 60,
        format('amount=%',
               (SELECT amount FROM expenses
                WHERE id = '00000000-0000-0000-0000-0000000000b4')));
    PERFORM tests.assert('لا تسرّب من مزرعة أ إلى ب',
        (SELECT count(*) FROM expenses
          WHERE farm_id = '00000000-0000-0000-0000-000000000002') = 1,
        format('expenses_B=%',
               (SELECT count(*) FROM expenses
                WHERE farm_id = '00000000-0000-0000-0000-000000000002')));
END;
$b_untouched$;

-- ============================================================================
--  STEP 6) مدير النظام يتجاوز كل ذلك
--  If is_system_admin() lost its exception the whole admin console would go
--  dark, so it needs a test of its own.
-- ============================================================================
SELECT tests.set_user('00000000-0000-0000-0000-00000000000e');
SELECT tests.expect_rows('sysadmin يقرأ كل payments',
    'SELECT * FROM payments');
SELECT tests.expect_ok('sysadmin يُدرج في expenses بمزرعة أ',
    'INSERT INTO expenses (farm_id, date, category, description, amount) '
    'VALUES (''00000000-0000-0000-0000-000000000001'', ''2026-10-02'', '
    '''other'', ''إدخال نظام'', 10)');

-- ============================================================================
--  STEP 7) المزامنة نفسها ما زالت تعمل للمدير
--  sync_records_batch writes as the calling user, so a policy tightened one
--  step too far would break sync before it broke the UI. Assert the manager
--  can still push a financial record through the RPC.
-- ============================================================================
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
DO $sync_ok$
DECLARE
    v_res jsonb := public.sync_records_batch(
        '[{"table_name":"expenses","operation":"insert",
           "record_id":"00000000-0000-0000-0000-0000000000d1",
           "operation_id":"guard-sync-ok-1","previous_version":null,
           "farm_id":"00000000-0000-0000-0000-000000000001",
           "data":{"date":"2026-10-02","category":"other",
                   "description":"sync probe","amount":11}}]'::jsonb);
    v_status text := coalesce(v_res->'details'->0->>'status', 'null');
    v_msg    text := coalesce(v_res->'details'->0->>'message', '');
BEGIN
    IF v_status = 'ok' THEN
        RAISE NOTICE 'PASS [sync: المدير يدفع مصروفاً عبر sync_records_batch] status=%', v_status;
    ELSE
        RAISE EXCEPTION 'FAIL [sync] status=% msg=%', v_status, v_msg;
    END IF;
END;
$sync_ok$;

-- ============================================================================
--  STEP 8) العامل ما زال يستطيع شغلته التشغيلية
--  The fix must not have leaked into the operational tables. If a worker could
--  no longer record production, the app would be broken rather than secured.
-- ============================================================================
SELECT tests.set_user('00000000-0000-0000-0000-00000000000b');
SELECT tests.expect_ok('worker_a ما زال يُسجّل إنتاج بيض',
    'INSERT INTO egg_production (flock_id, date, cartons, total_eggs, worker_id) '
    'VALUES (''00000000-0000-0000-0000-0000000000a1'', ''2026-10-02'', 1, '
    '360, ''00000000-0000-0000-0000-00000000000b'')');
SELECT tests.expect_ok('worker_a ما زال يُسجّل نفوقاً',
    'INSERT INTO mortality (flock_id, date, count, reason, worker_id) VALUES '
    '(''00000000-0000-0000-0000-0000000000a1'', ''2026-10-02'', 1, '
    '''unknown'', ''00000000-0000-0000-0000-00000000000b'')');
SELECT tests.expect_ok('worker_a ما زال يُسجّل استهلاك علف',
    'INSERT INTO feed_consumption (flock_id, date, entry_mode, quantity_kg, '
    'worker_id) VALUES (''00000000-0000-0000-0000-0000000000a1'', '
    '''2026-10-02'', ''kg'', 5, '
    '''00000000-0000-0000-0000-00000000000b'')');

-- Operational writes landed: confirm as sysadmin that the worker's rows are
-- really there. As worker_a they are not visible for the stock tables, so
-- expect_ok alone would not prove the insert persisted.
SELECT tests.set_user('00000000-0000-0000-0000-00000000000e');
DO $ops_ok$
BEGIN
    PERFORM tests.assert('صفوف العامل التشغيلية حُفظت فعلاً',
        (SELECT count(*) FROM egg_production
          WHERE worker_id = '00000000-0000-0000-0000-00000000000b') = 1
        AND (SELECT count(*) FROM mortality
              WHERE worker_id = '00000000-0000-0000-0000-00000000000b') = 1
        AND (SELECT count(*) FROM feed_consumption
              WHERE worker_id = '00000000-0000-0000-0000-00000000000b') = 1,
        format('egg=%s mort=%s feed=%s',
               (SELECT count(*) FROM egg_production
                 WHERE worker_id = '00000000-0000-0000-0000-00000000000b'),
               (SELECT count(*) FROM mortality
                 WHERE worker_id = '00000000-0000-0000-0000-00000000000b'),
               (SELECT count(*) FROM feed_consumption
                 WHERE worker_id = '00000000-0000-0000-0000-00000000000b')));
END;
$ops_ok$;

-- ============================================================================
--  STEP 9) الفحص البنيوي النهائي — لا سياسة متساهلة باقية
--  Mirrors the verification block in 20261002000000_restore_financial_rls.sql,
--  so the invariant is asserted at test time and not only at migration time.
-- ============================================================================
DO $structural$
DECLARE
    v_tables text[] := ARRAY[
        'payments', 'expenses', 'revenue',
        'opening_balances', 'inventory_items', 'stock_adjustments'
    ];
    t text;
    p record;
    v_pred text;
    v_seen int := 0;
BEGIN
    FOREACH t IN ARRAY v_tables LOOP
        FOR p IN
            SELECT policyname, cmd, roles::text AS roles_txt,
                   coalesce(qual, '') AS q,
                   coalesce(with_check, '') AS wc
              FROM pg_policies
             WHERE schemaname = 'public' AND tablename = t
        LOOP
            v_pred := CASE WHEN p.cmd = 'INSERT' THEN p.wc
                           ELSE p.q || ' ' || p.wc END;
            PERFORM tests.assert(
                format('سياسة %s.%s (%s) مُقيّدة بمدير', t, p.policyname, p.cmd),
                v_pred <> ''
                AND (v_pred ILIKE '%user_manages_farm%'
                     OR v_pred ILIKE '%system_admin%'),
                left(v_pred, 120));
            -- `TO public` is as fatal as `TO anon` and is NOT caught by testing
            -- for 'anon' alone: the roles array then reads {public} and never
            -- names anon, so a public-granted policy would slip past.
            PERFORM tests.assert(
                format('سياسة %s.%s مقصورة على authenticated', t, p.policyname),
                position('anon' in p.roles_txt) = 0
                AND position('public' in p.roles_txt) = 0,
                p.roles_txt);
            v_seen := v_seen + 1;
        END LOOP;
        PERFORM tests.assert(format('الجدول %s له سياسات', t), v_seen > 0, '');
        v_seen := 0;
    END LOOP;
END;
$structural$;

-- ============================================================================
--  النتيجة
-- ============================================================================
DO $final$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'p0_financial_rls_guard_test: كل الفحوص PASS';
    RAISE NOTICE 'العامل ممنوع من الجداول المالية الستة.';
    RAISE NOTICE 'المدير مقيّد بمزرعته. مدير النظام يتجاوز. التشغيل سليم.';
    RAISE NOTICE 'ROLLBACK — لا تغيير دائم.';
    RAISE NOTICE '============================================================';
END;
$final$;

ROLLBACK;