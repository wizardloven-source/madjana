-- ============================================================
-- ROLLBACK M4: flocks.archived + archived_at
-- ============================================================
-- Guard: blocked if any flock is archived.
-- ============================================================

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM flocks WHERE status = 'archived') THEN
        RAISE EXCEPTION 'cannot rollback: flocks are archived';
    END IF;
END;
$$;

-- Drop guard trigger first
DROP TRIGGER IF EXISTS trg_guard_flock_archive ON public.flocks;
DROP FUNCTION IF EXISTS public.trg_guard_flock_archive();

-- Drop RLS policy
DROP POLICY IF EXISTS op_select ON public.flocks;

-- Drop indexes
DROP INDEX IF EXISTS idx_flocks_archived_at;
DROP INDEX IF EXISTS idx_flocks_status;

-- Drop archived_at
ALTER TABLE flocks DROP COLUMN IF EXISTS archived_at;

-- Restore original status constraint
ALTER TABLE flocks
    DROP CONSTRAINT IF EXISTS flocks_status_check,
    ADD CONSTRAINT flocks_status_check
        CHECK (status IN ('active', 'depleted'));

COMMIT;