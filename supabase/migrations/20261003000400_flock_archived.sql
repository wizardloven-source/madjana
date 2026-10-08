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

-- 5. RLS: farm-scoped read; workers don't see archived, managers do.
--    v1 of this policy read `current_user_role() = 'manager'` UNSCOPED.
--    Policies are PERMISSIVE and compose with OR, so that one branch
--    granted every manager of every farm a read on EVERY flock -- a
--    cross-farm leak that p0_isolation_and_sync_test (suite 4a) caught.
--
--    flocks_read must carry the same scope, for two reasons:
--      * it alone would keep handing archived rows to workers -- the
--        union of permissive policies is what a role actually sees; and
--      * without the manager clause a manager could no longer open her
--        own archived flocks through the base policy either.
--
--    The leaky op_select on flocks is dropped, not repaired: flocks
--    already has a properly named read policy, and a second one with
--    identical scope is one more thing to keep in sync for no gain.
DROP POLICY IF EXISTS flocks_read ON public.flocks;
CREATE POLICY flocks_read ON public.flocks FOR SELECT TO authenticated
    USING (
        is_system_admin()
        OR (user_has_farm_access(farm_id) AND
            (current_user_role() = 'manager' OR status <> 'archived'))
    );

DROP POLICY IF EXISTS op_select ON public.flocks;

COMMIT;
