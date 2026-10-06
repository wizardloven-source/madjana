-- =============================================================================
--  test_grants.sql
--  Runs AFTER the base schema and migrations, because it grants on the objects
--  they create.
--
--  On Supabase the service_role key bypasses RLS AND carries broad table grants.
--  The shim creates the role as NOLOGIN BYPASSRLS but cannot grant on tables
--  that do not exist yet, so the grants are applied here instead. The
--  behavioural suite uses service_role for fixture maintenance and for every
--  read-back assertion.
-- =============================================================================

GRANT ALL ON ALL TABLES    IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO service_role;

-- and for anything a future migration adds
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;

-- storage shim tables too
GRANT ALL ON ALL TABLES IN SCHEMA storage TO service_role;

-- auth shim tables. On a real project GoTrue owns auth.users and the API roles
-- get no access to it; the shim has no GoTrue, and public.users.id references
-- auth.users(id), so the suite seeds both and needs to write here.
GRANT USAGE ON SCHEMA auth TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA auth TO service_role;

-- ── test_runner ─────────────────────────────────────────────────────────────
-- The SQL regression tests (p0_isolation_and_sync_test.sql,
-- revenue_sync_regression_test.sql) switch the caller's identity with
-- set_config('request.jwt.claims', ...) and then assert that raw SELECTs are
-- blocked by RLS. They never change the session ROLE, so they are only a real
-- test when the session role is an ordinary API role: postgres is NOSUPERUSER
-- off locally but is a superuser here, and a superuser bypasses RLS
-- unconditionally, which makes every "must be denied" case wrongly succeed.
--
-- test_runner is that ordinary role: it inherits authenticated's grants and
-- table policies, cannot bypass RLS, and may create the tests.* helpers.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'test_runner') THEN
        CREATE ROLE test_runner NOLOGIN NOSUPERUSER NOBYPASSRLS;
    END IF;
END
$$;

GRANT authenticated TO test_runner;
GRANT USAGE, CREATE ON SCHEMA tests  TO test_runner;
GRANT USAGE ON SCHEMA public, auth  TO test_runner;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO test_runner;

-- revenue_sync_regression_test.sql starts with CREATE SCHEMA IF NOT EXISTS tests,
-- and creating a schema needs CREATE on the database, not just on the schema.
-- current_database() keeps this file independent of the database name.
DO $$
BEGIN
    EXECUTE format('GRANT CREATE ON DATABASE %I TO test_runner',
                   current_database());
END
$$;

-- The two tables recovered by 20260927000000 were missing from the
-- GRANT ALL ON ALL TABLES above, because that statement runs against the
-- tables that existed when this file executes, and the recovery migration
-- creates its tables with its own connection. test_runner then hit
-- "permission denied for table flock_movements" and, because the suite runs
-- inside a transaction, every statement after it was rejected as well.
-- Naming them explicitly is the fix; the default privileges below cover
-- anything created later.
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['flock_movements', 'sync_table_registry'] LOOP
        IF to_regclass('public.' || t) IS NOT NULL THEN
            EXECUTE format('GRANT ALL ON public.%I TO test_runner', t);
            EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
        END IF;
    END LOOP;
END
$$;