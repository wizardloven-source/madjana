-- ============================================================================
-- P0 M4: flocks.archived + archived_at
-- ============================================================================
-- The rules under test:
--   * status: active | depleted | archived; archived is one-way
--     (trg_guard_flock_archive refuses archived -> active/depleted and
--     stamps archived_at on the way in)
--   * RLS: workers don't see archived flocks, managers and admins do,
--     and nobody reads another farm's flocks (the first version of this
--     policy leaked farm B to every manager -- suite 4a caught it)
--
-- Runs inside BEGIN/ROLLBACK. Fixtures from local_fixtures.sql
-- (FARM_A ...0001, FARM_B ...0002, admin_a ...000a, worker_a ...000b).
--   psql -f supabase/tests/p0_flock_archived_test.sql
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
    v_admin_a  uuid := '00000000-0000-0000-0000-00000000000a';
    v_worker_a uuid := '00000000-0000-0000-0000-00000000000b';
    v_sysadm   uuid := '00000000-0000-0000-0000-00000000000e';
    v_arch     uuid;   -- the flock we archive
    v_live     uuid;   -- stays active, proves workers still see something
    v_n        int;
    v_val      text;
    v_at       timestamptz;
BEGIN
    -- ── fixtures ─────────────────────────────────────────────────────────
    -- farm B gets a flock too, so the cross-farm read check has a target.
    PERFORM tests.set_user(v_sysadm);
    INSERT INTO public.flocks (farm_id, breed, initial_count, current_count,
                               start_date, status)
    VALUES (v_farm_b, 'M4 Flock B', 400, 400, CURRENT_DATE - 10, 'active');

    PERFORM tests.set_user(v_admin_a);
    INSERT INTO public.flocks (farm_id, breed, initial_count, current_count,
                               start_date, status)
    VALUES (v_farm_a, 'M4 Flock Arch', 300, 300, CURRENT_DATE - 10, 'active')
    RETURNING id INTO v_arch;
    INSERT INTO public.flocks (farm_id, breed, initial_count, current_count,
                               start_date, status)
    VALUES (v_farm_a, 'M4 Flock Live', 200, 200, CURRENT_DATE - 10, 'active')
    RETURNING id INTO v_live;

    -- ── 1. active -> depleted accepted ───────────────────────────────────
    UPDATE flocks SET status = 'depleted' WHERE id = v_arch;
    SELECT status INTO v_val FROM flocks WHERE id = v_arch;
    PERFORM tests.expect('active -> depleted', v_val = 'depleted');

    -- ── 2. depleted -> archived accepted ─────────────────────────────────
    UPDATE flocks SET status = 'archived' WHERE id = v_arch;
    SELECT status INTO v_val FROM flocks WHERE id = v_arch;
    PERFORM tests.expect('depleted -> archived', v_val = 'archived');

    -- ── 3. archived_at stamped by the guard trigger ──────────────────────
    SELECT archived_at INTO v_at FROM flocks WHERE id = v_arch;
    PERFORM tests.expect('archived_at stamped', v_at IS NOT NULL);

    -- ── 4. archived_at is timestamptz ────────────────────────────────────
    PERFORM tests.expect('archived_at is timestamptz',
        (SELECT data_type = 'timestamp with time zone'
           FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'flocks'
            AND column_name = 'archived_at'));

    -- ── 5. status CHECK accepts archived ─────────────────────────────────
    -- pg_constraint + pg_get_constraintdef are accessible under the suite's
    -- test_runner role; information_schema.check_constraints is not, and the
    -- check_clause column is the source of this failure.
    PERFORM tests.expect('status CHECK allows archived',
        (SELECT EXISTS (
            SELECT 1 FROM pg_constraint c
             WHERE c.conname = 'flocks_status_check' AND c.contype = 'c'
               AND pg_get_constraintdef(c.oid) LIKE '%archived%')));

    -- ── 6. unknown status rejected ───────────────────────────────────────
    BEGIN
        INSERT INTO public.flocks (farm_id, breed, initial_count,
                                   current_count, start_date, status)
        VALUES (v_farm_a, 'Bad Status', 0, 0, CURRENT_DATE, 'unknown');
        PERFORM tests.expect('unknown status rejected', false, 'accepted');
    EXCEPTION WHEN check_violation THEN
        PERFORM tests.expect('unknown status rejected', true);
    END;

    -- ── 7. archived -> active rejected ───────────────────────────────────
    BEGIN
        UPDATE flocks SET status = 'active' WHERE id = v_arch;
        PERFORM tests.expect('archived -> active rejected', false, 'accepted');
    EXCEPTION WHEN raise_exception THEN
        PERFORM tests.expect('archived -> active rejected', true);
    END;

    -- ── 8. archived -> depleted rejected ─────────────────────────────────
    BEGIN
        UPDATE flocks SET status = 'depleted' WHERE id = v_arch;
        PERFORM tests.expect('archived -> depleted rejected', false, 'accepted');
    EXCEPTION WHEN raise_exception THEN
        PERFORM tests.expect('archived -> depleted rejected', true);
    END;

    -- ── 9. archived survives both attempts ───────────────────────────────
    SELECT status INTO v_val FROM flocks WHERE id = v_arch;
    PERFORM tests.expect('archived persists', v_val = 'archived');
    -- ── 10-13. structural: indexes, trigger, constraint ──────────────────
    PERFORM tests.expect('index idx_flocks_status exists',
        EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = 'public' AND indexname = 'idx_flocks_status'));
    PERFORM tests.expect('index idx_flocks_archived_at exists',
        EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = 'public'
                   AND indexname = 'idx_flocks_archived_at'));
    PERFORM tests.expect('trigger trg_guard_flock_archive exists',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.flocks'::regclass
                   AND tgname = 'trg_guard_flock_archive' AND NOT tgisinternal));
    PERFORM tests.expect('constraint flocks_status_check exists',
        EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'flocks_status_check'
                   AND conrelid = 'public.flocks'::regclass));

    -- ── 14. flocks_read carries the archived rule ────────────────────────
    PERFORM tests.expect('flocks_read policy exists',
        EXISTS (SELECT 1 FROM pg_policies
                 WHERE tablename = 'flocks' AND policyname = 'flocks_read'));

    -- ── 15. the leaky op_select is gone from flocks ──────────────────────
    -- (customers keeps its own op_select; this asserts the flocks one)
    PERFORM tests.expect('leaky op_select absent on flocks',
        NOT EXISTS (SELECT 1 FROM pg_policies
                     WHERE schemaname = 'public' AND tablename = 'flocks'
                       AND policyname = 'op_select'));

    -- ── 16. worker does NOT see archived rows ────────────────────────────
    PERFORM tests.set_user(v_worker_a);
    SELECT count(*) INTO v_n FROM flocks
     WHERE farm_id = v_farm_a AND status = 'archived';
    PERFORM tests.expect('worker sees 0 archived flocks', v_n = 0,
                         format('got %s rows', v_n));

    -- ── 17. worker still sees active flocks of her farm ──────────────────
    SELECT count(*) INTO v_n FROM flocks
     WHERE farm_id = v_farm_a AND status <> 'archived';
    PERFORM tests.expect('worker sees active flocks', v_n >= 1,
                         format('got %s rows', v_n));

    -- ── 18. manager DOES see archived flocks of her farm ─────────────────
    PERFORM tests.set_user(v_admin_a);
    SELECT count(*) INTO v_n FROM flocks
     WHERE farm_id = v_farm_a AND status = 'archived';
    PERFORM tests.expect('manager sees archived flocks', v_n >= 1,
                         format('got %s rows', v_n));

    -- ── 19. nobody reads another farm's flocks (the suite-4a leak) ───────
    SELECT count(*) INTO v_n FROM flocks WHERE farm_id = v_farm_b;
    PERFORM tests.expect('admin_a sees 0 flocks of farm B', v_n = 0,
                         format('got %s rows — leak', v_n));

    -- ── 20. inserting a flock already archived is accepted ───────────────
    INSERT INTO public.flocks (farm_id, breed, initial_count, current_count,
                               start_date, status)
    VALUES (v_farm_a, 'M4 PreArchived', 50, 50, CURRENT_DATE - 10, 'archived')
    RETURNING id INTO v_live;
    PERFORM tests.expect('insert as archived accepted', v_live IS NOT NULL);

    -- ── 21. archiving leaves no tombstone ────────────────────────────────
    SELECT deleted_at INTO v_at FROM flocks WHERE id = v_arch;
    PERFORM tests.expect('no tombstone for archived', v_at IS NULL);

    RAISE NOTICE 'M4 behavioural block passed';
END $$;

-- ── 22-23. idempotency: re-run M4's DDL exactly as the migration does ────
-- DDL needs table ownership; test_runner has none (same reason as M5).
SET ROLE postgres;

ALTER TABLE flocks
    DROP CONSTRAINT IF EXISTS flocks_status_check,
    ADD CONSTRAINT flocks_status_check
        CHECK (status IN ('active', 'depleted', 'archived'));

ALTER TABLE flocks ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_flocks_status
    ON flocks(status) WHERE status <> 'archived';

CREATE INDEX IF NOT EXISTS idx_flocks_archived_at
    ON flocks(archived_at) WHERE archived_at IS NOT NULL;

CREATE OR REPLACE FUNCTION public.trg_guard_flock_archive()
RETURNS TRIGGER LANGUAGE plpgsql AS $fn$
BEGIN
    IF OLD.status = 'archived' AND NEW.status = 'active' THEN
        RAISE EXCEPTION 'cannot reactivate an archived flock';
    END IF;
    IF OLD.status = 'archived' AND NEW.status = 'depleted' THEN
        RAISE EXCEPTION 'cannot move an archived flock to depleted';
    END IF;
    IF NEW.status = 'archived' AND OLD.status <> 'archived' THEN
        NEW.archived_at := NOW();
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_guard_flock_archive ON public.flocks;
CREATE TRIGGER trg_guard_flock_archive
    BEFORE UPDATE OF status ON flocks
    FOR EACH ROW EXECUTE FUNCTION public.trg_guard_flock_archive();

DROP POLICY IF EXISTS flocks_read ON public.flocks;
CREATE POLICY flocks_read ON public.flocks FOR SELECT TO authenticated
    USING (
        is_system_admin()
        OR (user_has_farm_access(farm_id) AND
            (current_user_role() = 'manager' OR status <> 'archived'))
    );

DROP POLICY IF EXISTS op_select ON public.flocks;

DO $$
BEGIN
    PERFORM tests.expect('idempotent: flocks_read survives re-run',
        EXISTS (SELECT 1 FROM pg_policies
                 WHERE tablename = 'flocks' AND policyname = 'flocks_read'));
    PERFORM tests.expect('idempotent: op_select stays absent on flocks',
        NOT EXISTS (SELECT 1 FROM pg_policies
                     WHERE schemaname = 'public' AND tablename = 'flocks'
                       AND policyname = 'op_select'));
    RAISE NOTICE 'M4: all assertions passed.';
END;
$$;

ROLLBACK;