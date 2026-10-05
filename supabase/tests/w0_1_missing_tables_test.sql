-- ============================================================================
-- W0.1 — regression tests for the two recovered tables
-- ============================================================================
-- Covers:
--   1. flock_movements: the farm/flock consistency guard
--   2. flock_movements: worker attribution guard + SET NULL on user delete
--   3. sync_table_registry: every allowlisted table exists; order is sane
--   4. egg_dispatch / feed_received: the late flock_farm guard
--
-- Runs inside BEGIN/ROLLBACK, so nothing here persists.
-- Fixtures come from local_fixtures.sql (FARM_A/FARM_B, worker_a/worker_b).
-- Run with:  psql -f supabase/tests/w0_1_missing_tables_test.sql
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS tests;

-- Switches the simulated identity. Same GUC trick the other suites use.
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
        RAISE NOTICE 'PASS  %', rpad(p_label, 58, '.');
    ELSE
        RAISE EXCEPTION 'FAIL  %  %', p_label, p_detail;
    END IF;
END;
$$;

DO $$
DECLARE
    v_farm_a     uuid := '00000000-0000-0000-0000-000000000001';
    v_farm_b     uuid := '00000000-0000-0000-0000-000000000002';
    v_worker_a   uuid := '00000000-0000-0000-0000-00000000000b';
    v_worker_b   uuid := '00000000-0000-0000-0000-00000000000d';
    v_admin_a    uuid := '00000000-0000-0000-0000-00000000000a';
    v_sysadmin   uuid := '00000000-0000-0000-0000-00000000000e';
    v_flock_a    uuid;
    v_flock_b    uuid;
    v_mv_id      uuid;
    v_worker_id  uuid;
    v_msg        text;
BEGIN
    -- ── setup: one flock per farm ────────────────────────────────────────────
    INSERT INTO public.flocks (farm_id, breed, initial_count, current_count,
                                start_date, status)
    VALUES (v_farm_a, 'Test Layer A', 1000, 1000, CURRENT_DATE - 100, 'active'),
           (v_farm_b, 'Test Layer B',  800,  800,  CURRENT_DATE - 100, 'active');
    SELECT id INTO v_flock_a FROM public.flocks
     WHERE farm_id = v_farm_a AND breed = 'Test Layer A' LIMIT 1;
    SELECT id INTO v_flock_b FROM public.flocks
     WHERE farm_id = v_farm_b AND breed = 'Test Layer B' LIMIT 1;

    -- =====================================================================
    -- 1. flock_movements — farm/flock consistency
    -- =====================================================================
    PERFORM tests.expect('flock_movements table exists',
        to_regclass('public.flock_movements') IS NOT NULL);

    BEGIN
        INSERT INTO public.flock_movements
            (farm_id, flock_id, type, count, date)
        VALUES (v_farm_a, v_flock_a, 'addition', 250, CURRENT_DATE)
        RETURNING id INTO v_mv_id;
        PERFORM tests.expect('movement on own flock accepted', v_mv_id IS NOT NULL);
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('movement on own flock accepted', false, SQLERRM);
    END;

    -- a flock belonging to ANOTHER farm must be rejected
    BEGIN
        INSERT INTO public.flock_movements
            (farm_id, flock_id, type, count, date)
        VALUES (v_farm_a, v_flock_b, 'sale', 10, CURRENT_DATE);
        PERFORM tests.expect('cross-farm flock rejected', false,
            'accepted, but validate_flock_farm should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('cross-farm flock rejected', true);
    END;

    BEGIN
        INSERT INTO public.flock_movements
            (farm_id, flock_id, type, count, date)
        VALUES (v_farm_a, v_flock_a, 'addition', 0, CURRENT_DATE);
        PERFORM tests.expect('count = 0 rejected', false, 'CHECK (count > 0) missed');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('count = 0 rejected', true);
    END;

    BEGIN
        INSERT INTO public.flock_movements
            (farm_id, flock_id, type, count, date)
        VALUES (v_farm_a, v_flock_a, 'teleport', 5, CURRENT_DATE);
        PERFORM tests.expect('unknown movement type rejected', false,
            'CHECK on type missed');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('unknown movement type rejected', true);
    END;

    -- =====================================================================
    -- 2. worker attribution guard
    -- =====================================================================
    -- worker_a belongs to FARM_A -> allowed on FARM_A
    BEGIN
        INSERT INTO public.flock_movements
            (farm_id, flock_id, type, count, date, worker_id)
        VALUES (v_farm_a, v_flock_a, 'destruction', 3, CURRENT_DATE, v_worker_a);
        PERFORM tests.expect('same-farm worker attribution accepted', true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('same-farm worker attribution accepted', false, SQLERRM);
    END;

    -- worker_b belongs to FARM_B -> rejected on FARM_A
    BEGIN
        INSERT INTO public.flock_movements
            (farm_id, flock_id, type, count, date, worker_id)
        VALUES (v_farm_a, v_flock_a, 'destruction', 3, CURRENT_DATE, v_worker_b);
        PERFORM tests.expect('cross-farm worker attribution rejected', false,
            'accepted, but guard_worker_same_farm should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('cross-farm worker attribution rejected', true);
    END;

    -- a user_id with no membership at all is not a real account
    BEGIN
        INSERT INTO public.flock_movements
            (farm_id, flock_id, type, count, date, worker_id)
        VALUES (v_farm_a, v_flock_a, 'destruction', 3, CURRENT_DATE,
                '00000000-0000-0000-0000-0000000000ff');
        PERFORM tests.expect('non-existent worker rejected', false,
            'accepted, but guard_worker_same_farm should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('non-existent worker rejected', true);
    END;

    -- moving farm_id without touching worker_id must re-check too, or a row
    -- can be relocated to another farm carrying a stale attribution
    BEGIN
        UPDATE public.flock_movements
           SET farm_id = v_farm_b
         WHERE id = (SELECT id FROM public.flock_movements
                      WHERE worker_id = v_worker_a LIMIT 1);
        PERFORM tests.expect('farm_id change re-checks the worker', false,
            'row moved farm without re-validating the worker');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('farm_id change re-checks the worker', true);
    END;

    -- =====================================================================
    -- 3. worker_id ON DELETE SET NULL — the record must survive the user
    -- =====================================================================
    INSERT INTO public.flock_movements
        (farm_id, flock_id, type, count, date, worker_id)
    VALUES (v_farm_a, v_flock_a, 'destruction', 7, CURRENT_DATE, v_worker_a)
    RETURNING id INTO v_mv_id;

    SELECT worker_id INTO v_worker_id
      FROM public.flock_movements WHERE id = v_mv_id;
    PERFORM tests.expect('movement recorded with its worker',
        v_worker_id = v_worker_a);

    DELETE FROM auth.users WHERE id = v_worker_a;

    PERFORM tests.expect('movement SURVIVES the user deletion',
        EXISTS (SELECT 1 FROM public.flock_movements WHERE id = v_mv_id),
        'the row was destroyed along with the user');
    PERFORM tests.expect('worker_id blanked to NULL',
        (SELECT worker_id IS NULL FROM public.flock_movements WHERE id = v_mv_id),
        'worker_id was not set to NULL');

    -- restore the fixture for the suites that run after this one
    INSERT INTO auth.users (id, email, raw_user_meta_data)
    VALUES ('00000000-0000-0000-0000-00000000000b', 'worker_a@test.local',
            '{"role":"worker","full_name":"Test Worker A",
              "farm_id":"00000000-0000-0000-0000-000000000001"}')
    ON CONFLICT (id) DO UPDATE SET raw_user_meta_data = EXCLUDED.raw_user_meta_data;
    INSERT INTO public.user_farms (user_id, farm_id)
    VALUES ('00000000-0000-0000-0000-00000000000b',
            '00000000-0000-0000-0000-000000000001')
    ON CONFLICT DO NOTHING;

    -- =====================================================================
    -- 4. sync_table_registry
    -- =====================================================================
    PERFORM tests.expect('sync_table_registry table exists',
        to_regclass('public.sync_table_registry') IS NOT NULL);

    -- every listed table must really exist. This is the entire purpose of
    -- the registry, and the reason its absence broke sync with no message.
    SELECT string_agg(r.table_name, ', ') INTO v_msg
      FROM public.sync_table_registry r
     WHERE to_regclass('public.' || r.table_name) IS NULL;
    PERFORM tests.expect('every allowlisted table exists',
        v_msg IS NULL, 'missing: ' || COALESCE(v_msg, ''));

    -- parents must sort before children or a pull orphans rows
    SELECT string_agg(format('%s(%s) must sort before egg_production(%s)',
                            p.table_name, p.sort_order, c.sort_order), ' | ')
      INTO v_msg
      FROM public.sync_table_registry p
      JOIN public.sync_table_registry c ON c.table_name = 'egg_production'
     WHERE p.table_name IN ('farms', 'flocks', 'user_farms')
       AND p.sort_order >= c.sort_order;
    PERFORM tests.expect('parents sort before their children', v_msg IS NULL,
        COALESCE(v_msg, ''));

    PERFORM tests.expect('registry is populated, not an empty shell',
        (SELECT count(*) FROM public.sync_table_registry) > 0);

    -- =====================================================================
    -- 5. the late guards on egg_dispatch / feed_received
    -- =====================================================================
    PERFORM tests.expect('trg_validate_flock_dispatch installed',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.egg_dispatch'::regclass
                   AND tgname = 'trg_validate_flock_dispatch' AND NOT tgisinternal));
    PERFORM tests.expect('trg_validate_flock_feed_recv installed',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.feed_received'::regclass
                   AND tgname = 'trg_validate_flock_feed_recv' AND NOT tgisinternal));

    BEGIN
        INSERT INTO public.egg_dispatch
            (farm_id, flock_id, date, cartons, trays, total_eggs)
        VALUES (v_farm_a, v_flock_b, CURRENT_DATE, 1, 1, 180);
        PERFORM tests.expect('cross-farm egg_dispatch rejected', false,
            'accepted, but trg_validate_flock_dispatch should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('cross-farm egg_dispatch rejected', true);
    END;

    BEGIN
        INSERT INTO public.feed_received
            (farm_id, flock_id, date, quantity, quantity_kg, price_per_kg)
        VALUES (v_farm_a, v_flock_b, CURRENT_DATE, 1, 24, 0.5);
        PERFORM tests.expect('cross-farm feed_received rejected', false,
            'accepted, but trg_validate_flock_feed_recv should have raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('cross-farm feed_received rejected', true);
    END;

    -- =====================================================================
    -- 6. RLS — a manager must not read another farm's movements
    -- =====================================================================
    PERFORM tests.set_user(v_admin_a);
    PERFORM tests.expect('manager A sees own-farm movements',
        (SELECT count(*) FROM public.flock_movements WHERE farm_id = v_farm_a) > 0);
    PERFORM tests.expect('manager A sees NO FARM_B movements',
        (SELECT count(*) FROM public.flock_movements WHERE farm_id = v_farm_b) = 0);
    PERFORM tests.expect('sync_status defaults to pending',
        (SELECT sync_status FROM public.flock_movements
          WHERE farm_id = v_farm_a LIMIT 1) = 'pending');

    PERFORM tests.set_user(v_sysadmin);
    PERFORM tests.expect('sysadmin reads the whole registry',
        (SELECT count(*) FROM public.sync_table_registry) > 0);

    RAISE NOTICE '';
    RAISE NOTICE 'W0.1: all assertions passed.';
END $$;

ROLLBACK;
