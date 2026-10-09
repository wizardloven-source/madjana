-- ═════════════════════════════════════════════════════════════════════════════
-- M9 ROLLBACK — undo 20261003000900_app_schema_version.sql
-- ═════════════════════════════════════════════════════════════════════════════
--  To undo M9, run THIS file:
--      psql -f supabase/migrations/20261003000901_rollback_app_schema_version.sql
--
--  WHAT IT DOES
--  ------------
--  Removes the M9 schema-version marker entirely: the RPC
--  `current_schema_version()` and the `app_schema_version` table (its
--  `app_schema_version_read` policy goes with the table; there is nothing
--  to drop separately).
--
--  ⚠ AFTER THIS, current_schema_version() DOES NOT EXIST. An M9-enabled
--    client's boot gate treats a failed RPC as "offline" and does NOT block,
--    so nothing breaks — but the version contract is gone, and re-running
--    the forward migration is the only way back.
--
--  RE-RUN SAFE: every statement is IF EXISTS.
-- ═════════════════════════════════════════════════════════════════════════════

BEGIN;

SET LOCAL lock_timeout = '10s';

DROP FUNCTION IF EXISTS public.current_schema_version();

DROP TABLE IF EXISTS public.app_schema_version;

COMMIT;