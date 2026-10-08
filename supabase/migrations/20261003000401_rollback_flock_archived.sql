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

-- Drop the policy M4 added (only if an older copy of M4 created it)
DROP POLICY IF EXISTS op_select ON public.flocks;

-- Restore the pre-M4 read policy exactly as production has it
-- (json_output.txt: flocks_read = user_has_farm_access(farm_id)).
-- Without this, workers would stay locked out of archived rows the
-- moment 'archived' stops being a valid status, and the rollback
-- would not actually restore the old visibility.
DROP POLICY IF EXISTS flocks_read ON public.flocks;
CREATE POLICY flocks_read ON public.flocks FOR SELECT TO authenticated
    USING (user_has_farm_access(farm_id));

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