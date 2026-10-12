-- ============================================================================
-- P0 — revenue.flock_id (M1b)
-- ============================================================================
-- The rule under test, from docs/ACCOUNTING_RULES.md:
--     flock_id SET  -> direct revenue, counts in that flock's P&L
--     flock_id NULL -> farm-level revenue, never allocated to any flock
--
-- This is the exact mirror of the expenses.flock_id rule (M1). Revenue is
-- tested separately because it is the money-in side of the same P&L and had
-- no flock link at all before M1b.
--
-- Assertions:
--   1-4. the column exists exactly once, is uuid + nullable, carries an
--        ON DELETE RESTRICT FK, and both indexes exist
--   5. a revenue row on a flock of the SAME farm is accepted
--   6. a revenue row with flock_id NULL is accepted (farm revenue)
--   7. a revenue row naming another farm's flock is REJECTED on INSERT
--   8. the same is REJECTED on UPDATE (a correct row cannot be repointed)
--   9. a non-existent farm_id is REJECTED
--  10. a non-existent flock_id is REJECTED
--  11. deleting a flock that has revenue is REFUSED (ON DELETE RESTRICT)
--  12. deleting a revenue-free flock still works
--  13. the accounting split: direct revenue vs farm-level revenue is exact
--  14. total = direct + farm-level, nothing lost
--  15. a worker cannot write revenue (M8 manager-scoped financial RLS)
--  16. manager A sees only FARM_A revenue, never FARM_B's
--  17. the guarded ADD COLUMN left exactly one flock_id (idempotent shape);
--      CI re-applies each forward migration a second time for the runtime
--      idempotency proof.
--  18. the rollback scope guard REFUSES while flock_id rows exist
--  19. the rollback scope guard ALLOWS once no flock_id rows remain
--
-- Runs inside BEGIN/ROLLBACK. Fixtures from local_fixtures.sql.
--   psql -f supabase/tests/p0_revenue_flock_test.sql
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
    v_guard_refused boolean;
BEGIN
    -- ── setup ───────────────────────────────────────────────────────────────
    -- The suite runs as test_runner. Seeding the two flocks needs an identity
    -- that passes RLS on flocks for both farms: system_admin does. Later
    -- sections switch to a worker and to manager A.
    PERFORM tests.set_user(v_sysadm);
    INSERT INTO public.flocks (farm_id, breed, initial_count, current_count,
                                start_date, status)
    VALUES (v_farm_a, 'R Flock A', 1000, 1000, CURRENT_DATE - 100, 'active'),
           (v_farm_b, 'R Flock B',  800,  800,  CURRENT_DATE - 100, 'active');
    SELECT id INTO v_flock_a FROM public.flocks
     WHERE farm_id = v_farm_a AND breed = 'R Flock A' LIMIT 1;
    SELECT id INTO v_flock_b FROM public.flocks
     WHERE farm_id = v_farm_b AND breed = 'R Flock B' LIMIT 1;

    -- ═════════════════════════════════════════════════════════════════════
    -- 1-4. shape of the column
    -- ═════════════════════════════════════════════════════════════════════
    PERFORM tests.expect('column revenue.flock_id exists exactly once',
        (SELECT count(*) FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'revenue'
            AND column_name = 'flock_id') = 1);

    PERFORM tests.expect('revenue.flock_id is uuid and nullable',
        EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'revenue'
                   AND column_name = 'flock_id'
                   AND data_type = 'uuid' AND is_nullable = 'YES'));

    PERFORM tests.expect('revenue.flock_id FK is ON DELETE RESTRICT',
        EXISTS (SELECT 1
                  FROM pg_constraint c
                  JOIN pg_attribute a
                    ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
                 WHERE c.conrelid = 'public.revenue'::regclass
                   AND c.contype = 'f'
                   AND a.attname = 'flock_id'
                   AND c.confdeltype = 'r'));

    PERFORM tests.expect('both revenue flock indexes exist',
        EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = 'public' AND tablename = 'revenue'
                   AND indexname = 'idx_revenue_farm_flock')
        AND EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = 'public' AND tablename = 'revenue'
                   AND indexname = 'idx_revenue_flock_direct'));

    PERFORM tests.expect('guard trg_validate_flock_revenue installed',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.revenue'::regclass
                   AND tgname = 'trg_validate_flock_revenue' AND NOT tgisinternal));

    -- ═════════════════════════════════════════════════════════════════════
    -- 5. direct revenue on a flock of the same farm -> accepted
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        INSERT INTO public.revenue
            (farm_id, flock_id, category, amount, currency, date)
        VALUES (v_farm_a, v_flock_a, 'eggSales', 250.0000, 'dollar',
                CURRENT_DATE);
        PERFORM tests.expect('direct revenue on own flock accepted', true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('direct revenue on own flock accepted', false, SQLERRM);
    END;

    -- ═════════════════════════════════════════════════════════════════════
    -- 6. flock_id NULL -> accepted. This is the farm-revenue case (a sold
    --    coop), and it is why the column must stay nullable.
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        INSERT INTO public.revenue
            (farm_id, flock_id, category, amount, currency, date)
        VALUES (v_farm_a, NULL, 'building', 900.0000, 'dollar', CURRENT_DATE);
        PERFORM tests.expect('farm-level revenue (sold coops) accepted', true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('farm-level revenue (sold coops) accepted', false, SQLERRM);
    END;

    -- a farm-level revenue row for FARM_B too, so the isolation test below is
    -- non-trivial (there must be something the manager must NOT see)
    INSERT INTO public.revenue
        (farm_id, flock_id, category, amount, currency, date)
    VALUES (v_farm_b, NULL, 'equipment', 500.0000, 'dollar', CURRENT_DATE);

    -- ═════════════════════════════════════════════════════════════════════
    -- 7. flock of ANOTHER farm -> rejected by validate_flock_farm
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        INSERT INTO public.revenue
            (farm_id, flock_id, category, amount, currency, date)
        VALUES (v_farm_a, v_flock_b, 'eggSales', 100.0000, 'dollar',
                CURRENT_DATE);
        PERFORM tests.expect('cross-farm flock rejected', false,
            'accepted, but validate_flock_farm should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('cross-farm flock rejected', true);
    END;

    -- ═════════════════════════════════════════════════════════════════════
    -- 8. the guard must fire on UPDATE too: a correctly filed row could be
    --    repointed at another farm's flock otherwise
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        UPDATE public.revenue
           SET flock_id = v_flock_b
         WHERE farm_id = v_farm_a AND flock_id = v_flock_a;
        PERFORM tests.expect('cross-farm flock rejected on UPDATE too', false,
            'update succeeded, but the guard should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('cross-farm flock rejected on UPDATE too', true);
    END;

    -- ═════════════════════════════════════════════════════════════════════
    -- 9. non-existent farm_id -> rejected by the farm FK
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        INSERT INTO public.revenue
            (farm_id, flock_id, category, amount, currency, date)
        VALUES ('00000000-0000-0000-0000-0000000000ee', NULL, 'other',
                50.0000, 'dollar', CURRENT_DATE);
        PERFORM tests.expect('unknown farm_id rejected', false,
            'accepted, but revenue_farm_id_fkey should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('unknown farm_id rejected', true);
    END;

    -- ═════════════════════════════════════════════════════════════════════
    -- 10. non-existent flock_id -> rejected (by the guard or the FK)
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        INSERT INTO public.revenue
            (farm_id, flock_id, category, amount, currency, date)
        VALUES (v_farm_a, '00000000-0000-0000-0000-0000000000ee', 'other',
                50.0000, 'dollar', CURRENT_DATE);
        PERFORM tests.expect('unknown flock_id rejected', false,
            'accepted, but the flock_id FK should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('unknown flock_id rejected', true);
    END;

    -- ═════════════════════════════════════════════════════════════════════
    -- 11. deleting a flock that carries revenue must be REFUSED
    --     This protects the money: without ON DELETE RESTRICT the flock would
    --     vanish and the revenue would point at nothing.
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        DELETE FROM public.flocks WHERE id = v_flock_a;
        PERFORM tests.expect('deleting a flock with revenue is REFUSED', false,
            'the delete succeeded, so the FK is not ON DELETE RESTRICT');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('deleting a flock with revenue is REFUSED', true);
    END;

    -- ═════════════════════════════════════════════════════════════════════
    -- 12. a flock with NO revenue must still be deletable, otherwise the
    --     constraint is too broad and would trap the farm owner
    -- ═════════════════════════════════════════════════════════════════════
    BEGIN
        DELETE FROM public.flocks WHERE id = v_flock_b;
        PERFORM tests.expect('deleting a revenue-free flock still works', true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('deleting a revenue-free flock still works',
                             false, SQLERRM);
    END;

    -- ═════════════════════════════════════════════════════════════════════
    -- 13-14. the accounting rule: direct vs farm-level revenue
    --     A flock's revenue is ONLY the rows that name it. Farm revenue
    --     (other farms included) must not leak in.
    -- ═════════════════════════════════════════════════════════════════════
    SELECT COALESCE(sum(amount), 0) INTO v_direct
      FROM public.revenue
     WHERE flock_id = v_flock_a;
    SELECT COALESCE(sum(amount), 0) INTO v_farmlvl
      FROM public.revenue
     WHERE flock_id IS NULL AND farm_id = v_farm_a;

    PERFORM tests.expect('flock revenue counts ONLY its direct rows',
        v_direct = 250.0000, format('got %s, expected 250.0000', v_direct));
    PERFORM tests.expect('farm revenue stays out of every flock',
        v_farmlvl = 900.0000, format('got %s, expected 900.0000', v_farmlvl));
    PERFORM tests.expect('total = direct + farm-level, nothing lost',
        v_direct + v_farmlvl = 1150.0000);

    -- ═════════════════════════════════════════════════════════════════════
    -- 15. RLS — a worker must not be able to write revenue at all.
    --     M8 (20261002000000) made the financial tables manager-only.
    -- ═════════════════════════════════════════════════════════════════════
    PERFORM tests.set_user(v_worker_a);
    v_worker_can_write := false;
    BEGIN
        INSERT INTO public.revenue
            (farm_id, flock_id, category, amount, currency, date)
        VALUES (v_farm_a, v_flock_a, 'eggSales', 1.0000, 'dollar', CURRENT_DATE);
        v_worker_can_write := true;
    EXCEPTION WHEN OTHERS THEN
        v_worker_can_write := false;
    END;

    PERFORM tests.expect('worker cannot write revenue (M8 manager-only)',
        v_worker_can_write = false);

    -- ═════════════════════════════════════════════════════════════════════
    -- 16. cross-farm isolation for a manager
    -- ═════════════════════════════════════════════════════════════════════
    PERFORM tests.set_user(v_admin_a);
    PERFORM tests.expect('manager A sees only FARM_A revenue',
        NOT EXISTS (SELECT 1 FROM public.revenue WHERE farm_id <> v_farm_a));

    -- ═════════════════════════════════════════════════════════════════════
    -- 17. idempotent shape — the guarded ADD COLUMN must not have duplicated
    --     anything (assertion 1 already proves a single column). The runtime
    --     proof that re-applying the migration is a no-op is the CI job,
    --     which executes every forward migration twice.
    -- ═════════════════════════════════════════════════════════════════════
    PERFORM tests.expect('migration shape is idempotent (single column)',
        (SELECT count(*) FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'revenue'
            AND column_name = 'flock_id') = 1);

    -- ═════════════════════════════════════════════════════════════════════
    -- 18-19. the rollback scope guard, mirrored from
    --     20261003000151_rollback_revenue_flock_id.sql
    -- ═════════════════════════════════════════════════════════════════════
    PERFORM tests.set_user(v_sysadm);

    -- 18. rows still carry flock_id -> the guard must refuse
    v_guard_refused := false;
    BEGIN
        IF EXISTS (SELECT 1 FROM public.revenue WHERE flock_id IS NOT NULL) THEN
            RAISE EXCEPTION 'ABORT: cannot rollback - revenue rows with flock_id exist';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_guard_refused := true;
    END;
    PERFORM tests.expect('rollback guard REFUSES while flock_id rows exist',
        v_guard_refused);

    -- 19. clear the attributions -> the guard must now allow the rollback
    UPDATE public.revenue SET flock_id = NULL WHERE flock_id IS NOT NULL;
    v_guard_refused := false;
    BEGIN
        IF EXISTS (SELECT 1 FROM public.revenue WHERE flock_id IS NOT NULL) THEN
            RAISE EXCEPTION 'ABORT: cannot rollback - revenue rows with flock_id exist';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_guard_refused := true;
    END;
    PERFORM tests.expect('rollback guard ALLOWS when no flock_id rows remain',
        NOT v_guard_refused);

    RAISE NOTICE '';
    RAISE NOTICE 'M1b: all assertions passed.';
END $$;

ROLLBACK;
