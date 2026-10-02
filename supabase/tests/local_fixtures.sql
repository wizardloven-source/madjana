-- =============================================================================
--  local_fixtures.sql
--  The standard local identities the SQL regression tests are written against.
--
--  p0_isolation_and_sync_test.sql and revenue_sync_regression_test.sql both
--  hardcode these uuids and assume the rows already exist, because they were
--  written to be pasted into the Supabase SQL Editor against a database where
--  an operator had already created them by hand.
--
--  These are committed (not rolled back) by build_test_db.py so the two SQL
--  tests can run unattended. Names are all "Test ..." and the ids sit in the
--  00000000-0000-0000-0000-0000000000xx range, so they cannot collide with real
--  data -- and madjana_test is a scratch database anyway.
--
--  Users are created through auth.users because public.handle_new_user() is an
--  AFTER INSERT trigger that builds the public.users row from
--  raw_user_meta_data keys: role, full_name (not "name"), phone, farm_id.
--  The role cannot be set afterwards -- trg_guard_user_role_change is a BEFORE
--  UPDATE guard that requires is_system_admin(), which a brand-new user does
--  not yet have.
-- =============================================================================

-- ── farms ────────────────────────────────────────────────────────────────────
INSERT INTO public.farms (id, name, feed_bag_weight_kg, eggs_per_carton, eggs_per_tray)
VALUES ('00000000-0000-0000-0000-000000000001', 'FARM_A', 24, 30, 180),
       ('00000000-0000-0000-0000-000000000002', 'FARM_B', 50, 30, 180)
ON CONFLICT (id) DO NOTHING;

-- ── users, created via the real signup path ─────────────────────────────────
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES
    ('00000000-0000-0000-0000-00000000000a', 'admin_a@test.local',
     '{"role":"manager","full_name":"Test Admin A","farm_id":"00000000-0000-0000-0000-000000000001"}'),
    ('00000000-0000-0000-0000-00000000000b', 'worker_a@test.local',
     '{"role":"worker","full_name":"Test Worker A","farm_id":"00000000-0000-0000-0000-000000000001"}'),
    ('00000000-0000-0000-0000-00000000000c', 'admin_b@test.local',
     '{"role":"manager","full_name":"Test Admin B","farm_id":"00000000-0000-0000-0000-000000000002"}'),
    ('00000000-0000-0000-0000-00000000000d', 'worker_b@test.local',
     '{"role":"worker","full_name":"Test Worker B","farm_id":"00000000-0000-0000-0000-000000000002"}'),
    ('00000000-0000-0000-0000-00000000000e', 'sysadmin@test.local',
     '{"role":"system_admin","full_name":"Test Sys Admin"}')
ON CONFLICT (id) DO UPDATE SET raw_user_meta_data = EXCLUDED.raw_user_meta_data;

-- handle_new_user() uses ON CONFLICT DO NOTHING, so on a rebuild of the database
-- the public.users rows are created fresh; but if a row already exists with the
-- wrong role (left by an earlier test run), recreate it through the same path.
-- DELETE on auth.users cascades to public.users, then INSERT re-fires the trigger.
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT u.id, u.role FROM public.users u
        WHERE u.id IN ('00000000-0000-0000-0000-00000000000a',
                       '00000000-0000-0000-0000-00000000000b',
                       '00000000-0000-0000-0000-00000000000c',
                       '00000000-0000-0000-0000-00000000000d',
                       '00000000-0000-0000-0000-00000000000e')
    LOOP
        IF r.role NOT IN ('worker', 'manager', 'system_admin') THEN
            DELETE FROM auth.users WHERE id = r.id;
        END IF;
    END LOOP;
END $$;

-- Re-insert anything the loop above removed, so handle_new_user rebuilds the row
-- with the role from raw_user_meta_data rather than trying to UPDATE it.
INSERT INTO auth.users (id, email, raw_user_meta_data)
SELECT a.id, a.email, a.raw_user_meta_data
FROM (VALUES
    ('00000000-0000-0000-0000-00000000000a'::uuid, 'admin_a@test.local',
     '{"role":"manager","full_name":"Test Admin A","farm_id":"00000000-0000-0000-0000-000000000001"}'::jsonb),
    ('00000000-0000-0000-0000-00000000000b', 'worker_a@test.local',
     '{"role":"worker","full_name":"Test Worker A","farm_id":"00000000-0000-0000-0000-000000000001"}'::jsonb),
    ('00000000-0000-0000-0000-00000000000c', 'admin_b@test.local',
     '{"role":"manager","full_name":"Test Admin B","farm_id":"00000000-0000-0000-0000-000000000002"}'::jsonb),
    ('00000000-0000-0000-0000-00000000000d', 'worker_b@test.local',
     '{"role":"worker","full_name":"Test Worker B","farm_id":"00000000-0000-0000-0000-000000000002"}'::jsonb),
    ('00000000-0000-0000-0000-00000000000e', 'sysadmin@test.local',
     '{"role":"system_admin","full_name":"Test Sys Admin"}'::jsonb)
) AS a(id, email, raw_user_meta_data)
WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = a.id);

-- ── memberships ─────────────────────────────────────────────────────────────
-- admin_a -> FARM_A only, worker_a -> FARM_A. admin_b/worker_b own FARM_B.
-- The p0 test removes admin_a's FARM_A membership mid-transaction and restores
-- it, so no cross-farm membership may exist here.
INSERT INTO public.user_farms (user_id, farm_id)
VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000001'),
       ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000001'),
       ('00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-000000000002'),
       ('00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-000000000002')
ON CONFLICT DO NOTHING;