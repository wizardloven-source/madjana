-- ============================================================================
--  20261003000900_app_schema_version.sql
--  M9 — server-declared schema version, readable through PostgREST.
-- ============================================================================
--
--  WHY THIS MIGRATION EXISTS
--  ─────────────────────────
--  The app and the database can drift out of step: an installed build talks
--  to a server that has not received its matching migrations yet, or the
--  reverse. Before this migration no client could tell which side was ahead.
--
--  This adds a single-row version marker plus a tiny RPC the mobile and
--  desktop apps call at boot:
--
--      SELECT current_schema_version();   -- -> int (the highest version row)
--
--  The client compares the result against its OWN local schema version
--  (`packages/data/.../local_database.dart` `_dbVersion`, stored in
--  `local_schema_meta` since DB v30). The boot gate blocks sync when they
--  disagree:
--
--      server  > client  →  "الخادم أحدث — حدّث التطبيق"
--      client  > server  →  "التطبيق أحدث — ينتظر دعم الخادم"
--
--  The Sync Center (mobile) shows both versions side by side. Full contract
--  and bump procedure live in docs/SYNC.md.
--
--  The table is intentionally NOT in sync_table_registry: it is metadata
--  and must never replicate down to devices.
--
--  SECURITY NOTE: `app_schema_version` is the project's read-open exception
--  on purpose — a version number is not farm data, so the RLS policy uses
--  `USING (true)` and `anon` is NOT granted either SELECT or EXECUTE. Only
--  `authenticated` may read the table or call the RPC.
--
--  RE-RUN SAFE: every statement is IF EXISTS / OR REPLACE / ON CONFLICT,
--  so the CI double-apply loop and any re-apply after the rollback work.
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Version marker table (metadata only — never synced)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.app_schema_version (
    version integer NOT NULL PRIMARY KEY,
    min_client_version integer NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    notes text
);

-- Single row, value 1: the schema the first M9-enabled client targets.
-- ON CONFLICT so the CI re-apply loop is a no-op instead of an error.
INSERT INTO public.app_schema_version (version, min_client_version, notes)
VALUES (1, 1, 'initial')
ON CONFLICT (version) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RPC the client calls at boot
-- ─────────────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER so the caller does not need column-level table privileges;
-- STABLE so it is a constant within one statement and never writes.
-- search_path is pinned so the SECURITY DEFINER body cannot be redirected.
CREATE OR REPLACE FUNCTION public.current_schema_version()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT version
      FROM public.app_schema_version
     ORDER BY version DESC
     LIMIT 1;
$$;

-- Only authenticated (and its members) may read the version. anon is
-- deliberately excluded so the value is not exposed before auth.
GRANT SELECT ON public.app_schema_version TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_schema_version() TO authenticated;
-- PostgreSQL grants EXECUTE to PUBLIC by default for every new function —
-- a SECURITY DEFINER oracle that anon would inherit silently. Revoke it.
REVOKE EXECUTE ON FUNCTION public.current_schema_version() FROM PUBLIC;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RLS — read-open by design (see the header). No FORCE: the owner still
--    bypasses, which matches every other table in this schema.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.app_schema_version ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS app_schema_version_read ON public.app_schema_version;
CREATE POLICY app_schema_version_read ON public.app_schema_version
    FOR SELECT TO authenticated
    USING (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Verification — hard fail if the marker is not in place. This is the
--    guard that stops a future migration from bumping the number and leaving
--    the table empty, or dropping the function and silently blinding the
--    client version check.
-- ─────────────────────────────────────────────────────────────────────────────
DO $m9_verify$
DECLARE
    v_version int;
    v_rows int;
BEGIN
    SELECT count(*) INTO v_rows FROM public.app_schema_version;

    IF v_rows <> 1 THEN
        RAISE EXCEPTION
            'ABORT: app_schema_version has % rows (expected 1).', v_rows;
    END IF;

    SELECT current_schema_version() INTO v_version;

    IF v_version IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION
            'ABORT: current_schema_version() = % (expected 1).', v_version;
    END IF;

    RAISE NOTICE 'M9 verified: app_schema_version mark = 1, current_schema_version() = 1.';
END
$m9_verify$;

COMMIT;

-- ============================================================================
--  Post-apply checklist:
--
--    1. SELECT current_schema_version();      →  1
--    2. SELECT * FROM app_schema_version;    →  one row (1, 1, now(), 'initial')
--    3. As a real authenticated JWT:
--         curl "$SUPABASE_URL/rest/v1/rpc/current_schema_version" \
--              -H "apikey: $ANON" -H "Authorization: Bearer $USER_JWT"
--       → 1
--    4. Version control is documented in docs/SYNC.md.
-- ============================================================================