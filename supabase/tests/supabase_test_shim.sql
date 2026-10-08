-- =============================================================================
--  supabase_test_shim.sql
--  Minimal stand-in for the Supabase-managed objects the app depends on, so the
--  real migrations can run on a vanilla PostgreSQL 15 instance.
--
--  NOT production code. Test harness only. Nothing here is deployed.
--
--  Provides: roles (anon/authenticated/service_role), the auth schema with
--  auth.users and auth.uid(), auth.jwt(), auth.role(), auth.email(), and the
--  extensions schema with pgcrypto.
-- =============================================================================

-- ── roles ─────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        CREATE ROLE service_role NOLOGIN BYPASSRLS;
    END IF;
END
$$;

-- ── auth schema ───────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email              text UNIQUE,
    raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb,
    aud                text DEFAULT 'authenticated',
    role               text DEFAULT 'authenticated',
    created_at         timestamptz NOT NULL DEFAULT now(),
    -- GoTrue columns the app's writer functions touch (M6a p0 suite):
    encrypted_password text,
    email_confirmed_at  timestamptz,
    raw_app_meta_data  jsonb NOT NULL DEFAULT '{}'::jsonb,
    last_sign_in_at    timestamptz,
    updated_at         timestamptz
);

-- the block above only applies on a fresh build; a re-run against an existing
-- database (where CREATE TABLE IF NOT EXISTS is a no-op) still gets the columns
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS encrypted_password text;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS email_confirmed_at timestamptz;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS raw_app_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS last_sign_in_at timestamptz;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS updated_at timestamptz;

-- ── M6a app.* GUCs ─────────────────────────────────────────────────────────
-- The deploy suites verify the FIRST of these is set after the build and that
-- the SECOND was persisted by M6a (it auto-seeds app.v1_grace_until = now+7d).
-- Setting via ALTER ROLE postgres mirrors the Supabase instruction in
-- docs/SECURITY.md §8 (ALTER ROLE works from the SQL Editor; ALTER DATABASE
-- does not). This secret is a TEST-ONLY fake, never a real secret.
ALTER ROLE postgres SET app.pin_secret = 'madjana-test-secret';

-- app.v1_grace_until is auto-seeded by M6a to now+7d, but only while the GUC
-- is unset, and the role-level setting survives a DROP DATABASE rebuild -- so a
-- rebuild hours later would keep a stale grace and 4j's "grace = now + 7d"
-- window (+/-2h) would fail. Refresh the role-level value to a fresh now+7d on
-- every build, the same way pin_secret above is (re)set as a literal.
DO $$
BEGIN
    EXECUTE format('ALTER ROLE postgres SET app.v1_grace_until = %L',
                   (NOW() + interval '7 days')::text);
END
$$;

-- auth.uid(): reads the sub claim out of request.jwt.claims, exactly the way
-- PostgREST exposes it. Supports both the JSON and the legacy scalar setting.
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_claims text;
    v_sub    text;
BEGIN
    v_claims := current_setting('request.jwt.claims', true);
    IF v_claims IS NOT NULL AND v_claims <> '' THEN
        v_sub := v_claims::jsonb ->> 'sub';
    END IF;
    IF v_sub IS NULL OR v_sub = '' THEN
        v_sub := current_setting('request.jwt.claim.sub', true);
    END IF;
    IF v_sub IS NULL OR v_sub = '' THEN
        RETURN NULL;
    END IF;
    RETURN v_sub::uuid;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        NULLIF(current_setting('request.jwt.claims', true), '')::jsonb,
        '{}'::jsonb
    );
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        NULLIF(current_setting('request.jwt.claim.role', true), ''),
        NULLIF(auth.jwt() ->> 'role', ''),
        current_user::text
    );
$$;

CREATE OR REPLACE FUNCTION auth.email()
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(auth.jwt() ->> 'email', '');
$$;

-- ── storage schema (init.sql creates farm-scoped policies on storage.objects) ─
-- Only the surface the policies touch is needed: bucket_id, name, and foldername().
CREATE SCHEMA IF NOT EXISTS storage;

CREATE TABLE IF NOT EXISTS storage.buckets (
    id          text PRIMARY KEY,
    name        text,
    public      boolean NOT NULL DEFAULT false,
    created_at  timestamptz DEFAULT now(),
    updated_at  timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS storage.objects (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id    text REFERENCES storage.buckets(id),
    name         text,
    owner        uuid,
    created_at   timestamptz DEFAULT now(),
    updated_at   timestamptz DEFAULT now()
);

ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- Mirrors Supabase's implementation: splits the object path and drops the final
-- segment, so foldername('farms/<uuid>/mortality/a.jpg') = {farms,<uuid>,mortality}
CREATE OR REPLACE FUNCTION storage.foldername(name text)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    parts text[];
BEGIN
    IF name IS NULL OR name = '' THEN
        RETURN ARRAY[]::text[];
    END IF;
    SELECT string_to_array(name, '/') INTO parts;
    RETURN parts[1:COALESCE(array_length(parts, 1) - 1, 0)];
END;
$$;

-- ── tests schema ────────────────────────────────────────────────────────────
-- supabase/tests/p0_isolation_and_sync_test.sql creates helper functions
-- (tests.set_user, tests.expect_ok, tests.expect_fail) but never creates the
-- schema, so it only runs if something else made it first -- which is why it
-- works pasted into a Supabase SQL Editor session that already ran the revenue
-- test, and fails anywhere else. The shim creates it so both files run
-- standalone.
CREATE SCHEMA IF NOT EXISTS tests;

-- ── extensions schema (migrations call extensions.crypt / gen_salt) ───────────
CREATE SCHEMA IF NOT EXISTS extensions;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto') THEN
        CREATE EXTENSION pgcrypto WITH SCHEMA extensions;
    END IF;
END
$$;

-- NOTE: do not define public.gen_random_uuid(). It already exists in core
-- PG13+, and a wrapper here would resolve to itself and recurse forever.
-- The shim deliberately leaves it alone.