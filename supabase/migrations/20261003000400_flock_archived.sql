-- ============================================================
-- M4: flocks.archived + archived_at
-- ============================================================
-- Adds:
--   status CHECK (active|depleted|archived)
--   archived_at timestamptz NULL
--   trg_guard_flock_archive: blocks archived->active/depleted
--   RLS: workers don't see archived, managers do
-- ============================================================

BEGIN;

-- 1. Expand status constraint
ALTER TABLE flocks
    DROP CONSTRAINT IF EXISTS flocks_status_check,
    ADD CONSTRAINT flocks_status_check
        CHECK (status IN ('active', 'depleted', 'archived'));

-- 2. archived_at column
ALTER TABLE flocks
    ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;

-- 3. Partial indexes
CREATE INDEX IF NOT EXISTS idx_flocks_status
    ON flocks(status) WHERE status <> 'archived';

CREATE INDEX IF NOT EXISTS idx_flocks_archived_at
    ON flocks(archived_at) WHERE archived_at IS NOT NULL;

-- 4. Guard trigger: archived is one-way
CREATE OR REPLACE FUNCTION public.trg_guard_flock_archive()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- archived -> active : forbidden
    IF OLD.status = 'archived' AND NEW.status = 'active' THEN
        RAISE EXCEPTION 'cannot reactivate an archived flock';
    END IF;
    -- archived -> depleted : forbidden
    IF OLD.status = 'archived' AND NEW.status = 'depleted' THEN
        RAISE EXCEPTION 'cannot move an archived flock to depleted';
    END IF;
    -- entering archived: stamp it
    IF NEW.status = 'archived' AND OLD.status <> 'archived' THEN
        NEW.archived_at := NOW();
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_flock_archive ON public.flocks;
CREATE TRIGGER trg_guard_flock_archive
    BEFORE UPDATE OF status ON flocks
    FOR EACH ROW EXECUTE FUNCTION public.trg_guard_flock_archive();

-- 5. RLS: workers don't see archived; managers and admins do
DROP POLICY IF EXISTS op_select ON public.flocks;
CREATE POLICY op_select ON public.flocks FOR SELECT TO authenticated
    USING (
        is_system_admin()
        OR current_user_role() = 'manager'
        OR (farm_id = current_user_farm_id() AND status <> 'archived')
    );

COMMIT;
