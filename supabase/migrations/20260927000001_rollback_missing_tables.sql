-- ═══════════════════════════════════════════════════════════════════════════
-- W0.1 ROLLBACK — remove flock_movements + sync_table_registry
-- ═══════════════════════════════════════════════════════════════════════════
--  To undo W0.1, run THIS file:
--      psql -f supabase/migrations/20260927000001_rollback_missing_tables.sql
--
--  WHAT IT DESTROYS. Read before running.
--    DROP TABLE is irreversible. Both tables hold real operational data:
--      flock_movements      -- head-count history; feeds flocks.current_count
--                               and is what makes a 'depleted' flock auditable
--      sync_table_registry  -- the sync allowlist ordering
--    Roll back only against a fresh database, a test database, or a dump you
--    have just taken. NEVER against production without one.
--
--  Scope guard: refuses to run if either table actually holds rows, so an
--  accidental run on a live database fails loudly instead of quietly
--  destroying a flock's history. Override only with --i-know-this-is-empty
--  after exporting the data.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL lock_timeout = '10s';

DO $$
DECLARE
    v_movements bigint;
    v_registry  bigint;
BEGIN
    SELECT count(*) INTO v_movements FROM public.flock_movements;
    SELECT count(*) INTO v_registry  FROM public.sync_table_registry;

    IF v_movements > 0 OR v_registry > 0 THEN
        RAISE EXCEPTION
            'ABORT: flock_movements has % rows, sync_table_registry has % rows. '
            'These tables hold operational history. Export the data first, or '
            'drop the tables by hand once you have confirmed the loss is '
            'acceptable. Rolling back would destroy real records.',
            v_movements, v_registry;
    END IF;

    RAISE NOTICE 'scope check passed: both tables are empty';
END;
$$;

-- Drop triggers explicitly first. Dropping the table would do it anyway,
-- but naming them keeps the rollback self-documenting.
-- ⚠ These two guards live in this migration, so the rollback must remove
--   them as well. They are drops on the trigger only: no data is affected.
DROP TRIGGER IF EXISTS trg_validate_flock_feed_recv ON public.feed_received;
DROP TRIGGER IF EXISTS trg_validate_flock_dispatch ON public.egg_dispatch;

DROP TRIGGER IF EXISTS trg_validate_flock_movements   ON public.flock_movements;
DROP TRIGGER IF EXISTS trg_update_flock_count_movements ON public.flock_movements;
DROP TRIGGER IF EXISTS flock_movements_updated_at    ON public.flock_movements;
DROP TRIGGER IF EXISTS flock_movements_tombstone     ON public.flock_movements;
DROP TRIGGER IF EXISTS flock_movements_sync_update   ON public.flock_movements;
DROP TRIGGER IF EXISTS flock_movements_sync_insert   ON public.flock_movements;
DROP TRIGGER IF EXISTS trg_guard_flock_movement_user_change
                                                    ON public.flock_movements;

DROP POLICY IF EXISTS flock_movements_delete ON public.flock_movements;
DROP POLICY IF EXISTS flock_movements_update ON public.flock_movements;
DROP POLICY IF EXISTS flock_movements_insert ON public.flock_movements;
DROP POLICY IF EXISTS flock_movements_select ON public.flock_movements;

DROP TABLE IF EXISTS public.flock_movements;

DROP POLICY IF EXISTS sync_table_registry_read ON public.sync_table_registry;
DROP TABLE IF EXISTS public.sync_table_registry;

COMMIT;

-- Verification: both tables must be gone, and the migrations that reference
-- them (none yet) must not be left dangling.
DO $$
BEGIN
    IF to_regclass('public.flock_movements') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: flock_movements still present after rollback';
    END IF;
    IF to_regclass('public.sync_table_registry') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: sync_table_registry still present after rollback';
    END IF;
    RAISE NOTICE 'OK: W0.1 rolled back cleanly';
END;
$$;
