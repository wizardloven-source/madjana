-- ============================================================================
-- M31: make the production-only helper login_lock_window_minutes() reproducible
-- ============================================================================
-- WHY
--   Production exposes public.login_lock_window_minutes() -- it appears in the
--   live snapshot (json_output.txt) -- but NO repo file created it, so a
--   from-scratch rebuild silently omitted it and verify_schema_drift.py
--   reported real drift on the function.
--
--   The drift gate never caught this before because the checker could not parse
--   the regenerated json_output.txt and silently compared against an empty
--   reference. That parser bug is fixed, so the missing function now shows up
--   as drift and must exist in the numbered chain.
--
-- BODY
--   Mirrors the live definition verbatim (pg_get_functiondef): returns 30
--   (minutes), LANGUAGE sql IMMUTABLE, SECURITY DEFINER, search_path pinned.
--
-- SAFETY (production is NOT touched)
--   The CREATE is guarded by a catalog probe. When the function already
--   exists -- which it does in production -- this migration does nothing and
--   leaves the live definition byte-for-byte untouched. The body below is used
--   ONLY when building a fresh database, where no prior definition exists to
--   preserve. It is therefore safe to apply to the live database.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'login_lock_window_minutes'
    ) THEN
        EXECUTE $ddl$CREATE FUNCTION public.login_lock_window_minutes() RETURNS integer LANGUAGE sql IMMUTABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS 'SELECT 30';$ddl$;
    END IF;
END;
$guard$;

COMMIT;
