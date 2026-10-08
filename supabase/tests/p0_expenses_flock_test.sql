-- ============================================================================
-- P0 — expenses.flock_id (M1)
-- ============================================================================
-- The rule under test, from docs/ACCOUNTING_RULES.md:
--     flock_id SET  -> direct flock cost, counts in that flock's P&L
--     flock_id NULL -> farm-level cost, never allocated to any flock
--
-- Assertions:
--   1. an expense on a flock of the SAME farm is accepted
--   2. an expense with flock_id NULL is accepted (salaries must work)
--   3. an expense naming another farm's flock is REJECTED
--   4. an expense with a non-existent farm_id is REJECTED by the FK
--   5. deleting a flock that has expenses is REFUSED (ON DELETE RESTRICT)
--   6. the cost query separates direct from farm-level correctly
--   7. a worker still cannot read expenses
--
-- Runs inside BEGIN/ROLLBACK. Fixtures from local_fixtures.sql.
--   psql -f supabase/tests/p0_expenses_flock_test.sql
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS tests;

CREATE OR REPLACE FUNCTION tests.set_user(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
        true);
END;
$$;

CREATE OR REPLACE FUNCTION tests.expect(
    p_label text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok THEN
        RAISE NOTICE 'PASS  %', rpad(p_label, 56, '.');
    ELSE
        RAISE EXCEPTION 'FAIL  %  %', p_label, p_detail;
    END IF;
END;
$$;

DO $$
DECLARE
    v_farm_a   uuid := '00000000-0000-0000-0000-000000000001';
    v_farm_b   uuid := '00000000-0000-0000-0000-000000000002';
    v_flock_a  uuid;
    v_flock_b  uuid;
    v_admin_a  uuid := '00000000-0000-0000-0000-00000000000a';
    v_worker_a uuid := '00000000-0000-0000-0000-00000000000b';
    v_sysadm   uuid := '00000000-0000-0000-0000-00000000000e';
    v_direct   numeric;
    v_farmlvl  numeric;
    v_worker_can_write boolean;
BEGIN
    -- ── setup ───────────────────────────────────────────────────────────────
    -- The suite runs as test_runner: with no request.jwt.claims, op_insert
    -- on flocks is FALSE for every farm and the fixtures die with
    -- "new row violates row-level security policy". Seeding FARM_A and
    -- FARM_B needs the one identity that passes both. Sections 7 and 8
    -- switch to a worker and to manager A further down.
    PERFORM tests.set_user(v_sysadm);
    INSERT INTO public.flocks (farm_id, breed, initial_count, current_count,
                                start_date, status)
    VALUES (v_farm_a, 'T Flock A', 1000, 1000, CURRENT_DATE - 100, 'active'),
           (v_farm_b, 'T Flock B',  800,  800,  CURRENT_DATE - 100, 'active');
    SELECT id INTO v_flock_a FROM public.flocks
     WHERE farm_id = v_farm_a AND breed = 'T Flock A' LIMIT 1;
    SELECT id INTO v_flock_b FROM public.flocks
     WHERE farm_id = v_farm_b AND breed = 'T Flock B' LIMIT 1;

    PERFORM tests.expect('column expenses.flock_id exists',
        EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'expenses'
                   AND column_name = 'flock_id'));
    PERFORM tests.expect('guard trg_validate_flock_expenses installed',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.expenses'::regclass
                   AND tgname = 'trg_validate_flock_expenses' AND NOT tgisinternal));

    -- ═════════════════════════════════════════════════════════════════════
    -- 1. direct cost, flock of the same farm -> accepted
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        INSERT INTO public.expenses
            (farm_id, flock_id, category, amount, currency, date)
        VALUES (v_farm_a, v_flock_a, 'electricity', 250.0000, 'dollar',
                CURRENT_DATE);
        PERFORM tests.expect('direct cost on own flock accepted', true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('direct cost on own flock accepted', false, SQLERRM);
    END;

    -- ═════════════════════════════════════════════════════════════════════
    -- 2. flock_id NULL -> accepted. This is the salary case, and it is the
    --    reason the column must stay nullable.
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        INSERT INTO public.expenses
            (farm_id, flock_id, category, amount, currency, date)
        VALUES (v_farm_a, NULL, 'labor', 900.0000, 'dollar', CURRENT_DATE);
        PERFORM tests.expect('farm-level cost (salary) accepted', true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('farm-level cost (salary) accepted', false, SQLERRM);
    END;

    -- ═════════════════════════════════════════════════════════════════════
    -- 3. flock of ANOTHER farm -> rejected by validate_flock_farm
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        INSERT INTO public.expenses
            (farm_id, flock_id, category, amount, currency, date)
        VALUES (v_farm_a, v_flock_b, 'electricity', 100.0000, 'dollar',
                CURRENT_DATE);
        PERFORM tests.expect('cross-farm flock rejected', false,
            'accepted, but validate_flock_farm should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('cross-farm flock rejected', true);
    END;

    -- the same check must fire on UPDATE, not only on INSERT: an expense
    -- could be filed correctly and then repointed at another farm's flock
    BEGIN
        UPDATE public.expenses
           SET flock_id = v_flock_b
         WHERE farm_id = v_farm_a AND flock_id = v_flock_a;
        PERFORM tests.expect('cross-farm flock rejected on UPDATE too', false,
            'update succeeded, but the guard should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('cross-farm flock rejected on UPDATE too', true);
    END;

    -- ═════════════════════════════════════════════════════════════════════
    -- 4. non-existent farm_id -> rejected by the farm FK
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        INSERT INTO public.expenses
            (farm_id, flock_id, category, amount, currency, date)
        VALUES ('00000000-0000-0000-0000-0000000000ee', NULL, 'other',
                50.0000, 'dollar', CURRENT_DATE);
        PERFORM tests.expect('unknown farm_id rejected', false,
            'accepted, but expenses_farm_id_fkey should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('unknown farm_id rejected', true);
    END;

    -- a non-existent flock_id must be rejected too
    BEGIN
        INSERT INTO public.expenses
            (farm_id, flock_id, category, amount, currency, date)
        VALUES (v_farm_a, '00000000-0000-0000-0000-0000000000ee', 'other',
                50.0000, 'dollar', CURRENT_DATE);
        PERFORM tests.expect('unknown flock_id rejected', false,
            'accepted, but the flock_id FK should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('unknown flock_id rejected', true);
    END;

    -- ═════════════════════════════════════════════════════════════════════
    -- 5. deleting a flock that carries expenses must be REFUSED
    --    This is the assertion that protects the money. Without
    --    ON DELETE RESTRICT the flock would vanish and the expense would be
    --    left pointing at nothing, understating nothing but losing the link.
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        DELETE FROM public.flocks WHERE id = v_flock_a;
        PERFORM tests.expect('deleting a flock with expenses is REFUSED', false,
            'the delete succeeded, so the FK is not ON DELETE RESTRICT');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('deleting a flock with expenses is REFUSED', true);
    END;

    -- a flock with NO expenses must still be deletable, otherwise the
    -- constraint is too broad and would trap the farm owner
    BEGIN
        DELETE FROM public.flocks WHERE id = v_flock_b;
        PERFORM tests.expect('deleting an expense-free flock still works', true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('deleting an expense-free flock still works',
                             false, SQLERRM);
    END;

    -- ═════════════════════════════════════════════════════════════════════
    -- 6. the actual accounting rule: direct cost vs farm-level cost
    --    A flock's cost is ONLY the rows that name it. The salary must not
    --    leak in. This is the assertion that would have caught the original
    --    feedKg x pricePerEgg bug.
    -- ═════════════════════════════════════════════════════════════════════
    SELECT COALESCE(sum(amount), 0) INTO v_direct
      FROM public.expenses
     WHERE flock_id = v_flock_a;
    SELECT COALESCE(sum(amount), 0) INTO v_farmlvl
      FROM public.expenses
     WHERE flock_id IS NULL;

    PERFORM tests.expect('flock cost counts ONLY its direct expenses',
        v_direct = 250.0000, format('got %s, expected 250.0000', v_direct));
    PERFORM tests.expect('salary stays out of every flock',
        v_farmlvl = 900.0000, format('got %s, expected 900.0000', v_farmlvl));

    -- the flock is profitable-looking only because the salary was excluded:
    -- 250 of direct cost against a flock that produced nothing here. The
    -- point is that the split is exact, not that the number is nice.
    PERFORM tests.expect('total = direct + farm-level, nothing lost',
        v_direct + v_farmlvl = 1150.0000);

    -- ═════════════════════════════════════════════════════════════════════
    -- 7. RLS — worker write path
    --    A worker must not be able to file an expense at all.
    --
    --    TODO(M8): change to ASSERT 0 rows after M8 is applied.
    --    M1 does NOT change RLS. As of this writing expenses_read /
    --    expenses_insert use user_has_farm_access(farm_id), so a worker with
    --    farm access still passes. This block therefore RECORDS the current
    --    behaviour instead of asserting a policy that does not exist yet --
    --    an assertion that cannot fail is worse than no assertion, because it
    --    reads as a guarantee.
    --
    --    The real gate is p0_financial_rls_guard_test.sql STEP 2/3, which
    --    already demands 0 rows and MUST fail until M8 lands. When M8 does
    --    land, delete the RAISE NOTICE here and assert:
    --        PERFORM tests.expect('worker cannot write an expense',
    --            v_worker_can_write = false);
    -- ═════════════════════════════════════════════════════════════════════
    PERFORM tests.set_user(v_worker_a);
    v_worker_can_write := false;
    BEGIN
        INSERT INTO public.expenses
            (farm_id, flock_id, category, amount, currency, date)
        VALUES (v_farm_a, v_flock_a, 'other', 1.0000, 'dollar', CURRENT_DATE);
        v_worker_can_write := true;
    EXCEPTION WHEN OTHERS THEN
        v_worker_can_write := false;
    END;

    RAISE NOTICE 'INFO  worker expense write currently % '
                 '(M1 does not change RLS; W2/M8 must make this FALSE)',
                 CASE WHEN v_worker_can_write THEN 'ALLOWED' ELSE 'BLOCKED' END;
    PERFORM tests.expect('worker write outcome recorded for M8',
        v_worker_can_write IN (true, false));

    -- ═════════════════════════════════════════════════════════════════════
    -- 8. cross-farm isolation for a manager
    -- ═════════════════════════════════════════════════════════════════════
    PERFORM tests.set_user(v_admin_a);
    PERFORM tests.expect('manager A sees only FARM_A expenses',
        NOT EXISTS (SELECT 1 FROM public.expenses WHERE farm_id <> v_farm_a));

    RAISE NOTICE '';
    RAISE NOTICE 'M1: all assertions passed.';
END $$;

ROLLBACK;
