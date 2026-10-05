-- ═══════════════════════════════════════════════════════════════════════════
-- W0.1  ADD MISSING TABLES  --  flock_movements + sync_table_registry
-- ═══════════════════════════════════════════════════════════════════════════
--  PURPOSE
--    verify_schema_drift.py proved (json_output.txt = live production vs the
--    repo files) that TWO production tables exist that no repo file declares:
--        flock_movements      -- read by sync_table_registry / sync pull
--        sync_table_registry  -- the ordered allowlist of syncable tables
--    A `supabase db reset` / `db push` built from the repo therefore dropped
--    both, which is the most likely root cause of "sync fails silently".
--
--  DESIGN RULES (project conventions, see docs/SCHEMA_REFERENCE.md)
--    1. Fully IDEMPOTENT  -- IF NOT EXISTS / DROP TRIGGER IF EXISTS everywhere.
--       The tables ALREADY EXIST in production; this migration must be a
--       no-op on columns that are live and must only ADD what is missing.
--    2. Trigger / policy NAMES are copied VERBATIM from json_output.txt, not
--       invented. Production uses `flock_movements_sync_insert` (not
--       `trg_populate_sync`) and `*_select` (not `*_read`) for this table.
--       Renaming them here would make drift WORSE, not better.
--    3. No data is touched. No column is dropped, narrowed or retyped.
--    4. Every statement is `IF NOT EXISTS`-guarded so a partial previous run
--       can be resumed safely.
--
--  RE-RUN SAFE. IDEMPOTENT.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. flock_movements
--    A movement is one discrete change to the head count of a flock:
--    addition (birds bought in), sale (birds sold off), transfer (moved to
--    another flock), destruction (culled). `count` is always POSITIVE; the
--    `type` decides the sign. This is what trg_update_flock_count_movements
--    and the deleted 'depleted' flocks rely on.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.flock_movements (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id     uuid NOT NULL REFERENCES public.farms(id)  ON DELETE RESTRICT,
    flock_id    uuid NOT NULL REFERENCES public.flocks(id) ON DELETE RESTRICT,
    worker_id   uuid REFERENCES public.users(id) ON DELETE SET NULL,
    type        text NOT NULL
                CHECK (type IN ('addition', 'sale', 'transfer', 'destruction')),
    count       integer NOT NULL CHECK (count > 0),
    date        date NOT NULL,
    notes       text,
    version     bigint NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz
);

-- ── Columns production is missing ──────────────────────────────────────────
-- sync_status is the cross-table convention (every other synced table has
-- it). It is ADDED so the offline queue can report per-record state instead
-- of failing on an unknown column.
--
-- init.sql also creates a flock_movements, but WITHOUT sync_status and with
-- a narrower column set. Because this migration runs after that snapshot,
-- CREATE TABLE IF NOT EXISTS above is a no-op there, so the ALTERs below
-- are the only thing that can bring such a table up to date. Each is
-- therefore written to tolerate both shapes.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                     AND table_name = 'flock_movements'
                     AND column_name = 'sync_status') THEN
        ALTER TABLE public.flock_movements
            ADD COLUMN sync_status text NOT NULL DEFAULT 'pending';
        COMMENT ON COLUMN public.flock_movements.sync_status IS
            'pending | synced | failed | processing | conflict';
    END IF;

    -- init.sql declares `type` and `notes`; json_output.txt shows the same
    -- two columns, so no repair is needed. What it does NOT carry is the
    -- NOT NULL on flock_id / type / count, which is why those are re-stated
    -- as constraints below rather than trusted from the snapshot.
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'flock_movements_flock_id_fkey'
          AND conrelid = 'public.flock_movements'::regclass) THEN
        ALTER TABLE public.flock_movements
            ADD CONSTRAINT flock_movements_flock_id_fkey
            FOREIGN KEY (flock_id) REFERENCES public.flocks(id)
            ON DELETE RESTRICT;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'flock_movements_farm_id_fkey'
          AND conrelid = 'public.flock_movements'::regclass) THEN
        ALTER TABLE public.flock_movements
            ADD CONSTRAINT flock_movements_farm_id_fkey
            FOREIGN KEY (farm_id) REFERENCES public.farms(id)
            ON DELETE RESTRICT;
    END IF;
END;
$$;

-- The convention is enforced as a CHECK on every synced table. Created
-- separately so re-running never re-adds a second, identical constraint.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conname = 'flock_movements_sync_status_check'
                     AND conrelid = 'public.flock_movements'::regclass) THEN
        ALTER TABLE public.flock_movements
            ADD CONSTRAINT flock_movements_sync_status_check
            CHECK (sync_status IN ('pending', 'synced', 'failed',
                                   'processing', 'conflict'));
    END IF;
END;
$$;

-- ── Indexes ───────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_flock_movements_flock_date
    ON public.flock_movements (flock_id, date);
CREATE INDEX IF NOT EXISTS idx_flock_movements_farm
    ON public.flock_movements (farm_id);
-- Partial index: only rows that still need work are indexed.
CREATE INDEX IF NOT EXISTS idx_flock_movements_sync
    ON public.flock_movements (sync_status)
    WHERE sync_status <> 'synced';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. sync_table_registry
--    The ordered allowlist of tables the sync engine is allowed to move.
--    `sort_order` is the pull sequence: parents before children, so a device
--    never receives an egg_production row before its flock exists.
--    This table is the contract between the sync engine and the schema; when
--    a table is missing from it, data silently never syncs. That is why it is
--    reconstructed here rather than left to a file that was never generated.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.sync_table_registry (
    table_name  text PRIMARY KEY,
    sort_order  integer NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Seed with the production tables in dependency order. ON CONFLICT DO NOTHING
-- keeps an already-populated registry untouched: this migration declares the
-- SCHEMA, it must not rewrite the DATA.
INSERT INTO public.sync_table_registry (table_name, sort_order) VALUES
    ('farms',                  10),
    ('users',                  20),
    ('user_farms',             30),
    ('flocks',                 40),
    ('flock_movements',        50),
    ('opening_balances',       60),
    ('egg_production',         70),
    ('mortality',              80),
    ('feed_received',          90),
    ('feed_consumption',      100),
    ('medications',           110),
    ('customers',             120),
    ('egg_dispatch',          130),
    ('payments',              140),
    ('expenses',              150),
    ('revenue',               160),
    ('inventory_items',       170),
    ('inventory_transactions',180),
    ('stock_adjustments',     190),
    ('dispatch_requests',     200)
ON CONFLICT (table_name) DO NOTHING;

COMMENT ON TABLE public.sync_table_registry IS
    'Ordered allowlist of syncable tables. Parents precede children so a pull never orphans a row.';

-- ── RLS ───────────────────────────────────────────────────────────────────
-- Deliberately admin/manager only: a worker cannot read or rewrite the sync
-- contract, and there is no anon access. Managers need it for support; only
-- the system admin may change it.
ALTER TABLE public.sync_table_registry ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sync_table_registry_read ON public.sync_table_registry;
CREATE POLICY sync_table_registry_read ON public.sync_table_registry
    FOR SELECT TO authenticated
    USING (public.is_system_admin()
           OR public.current_user_role() = 'manager');

COMMIT;

-- ===========================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ===========================================================================

DO $$
DECLARE
    v_missing text;
BEGIN
    -- Both tables must exist and be RLS-enabled.
    IF to_regclass('public.flock_movements') IS NULL THEN
        RAISE EXCEPTION 'FAIL: public.flock_movements still missing';
    END IF;
    IF to_regclass('public.sync_table_registry') IS NULL THEN
        RAISE EXCEPTION 'FAIL: public.sync_table_registry still missing';
    END IF;

    -- RLS enabled on both.
    IF NOT (SELECT relrowsecurity FROM pg_class
             WHERE oid = 'public.flock_movements'::regclass) THEN
        RAISE EXCEPTION 'FAIL: RLS not enabled on flock_movements';
    END IF;

    -- The consistency guard must exist, otherwise principle 5/6 is unguarded.
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                   WHERE tgrelid = 'public.flock_movements'::regclass
                     AND tgname = 'trg_validate_flock_movements'
                     AND NOT tgisinternal) THEN
        -- Report WHY, because a bare "not installed" sent us looking in the
        -- wrong place. The usual cause is that CREATE TRIGGER failed on a
        -- missing function or a missing column, and the trigger was simply
        -- never created.
        RAISE EXCEPTION
            'FAIL: trg_validate_flock_movements not installed. '
            'validate_flock_farm() present: %; flock_id column present: %; '
            'existing triggers: %',
            (SELECT count(*) > 0 FROM pg_proc p
               JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public'
                AND p.proname = 'validate_flock_farm'),
            EXISTS (SELECT 1 FROM information_schema.columns
                     WHERE table_schema = 'public'
                       AND table_name = 'flock_movements'
                       AND column_name = 'flock_id'),
            (SELECT string_agg(tgname, ', ' ORDER BY tgname) FROM pg_trigger
              WHERE tgrelid = 'public.flock_movements'::regclass
                AND NOT tgisinternal);
    END IF;

    -- The sync triggers must exist, otherwise movements never sync at all.
    -- Names come from json_output.txt, which lists four on this table plus
    -- the two this migration adds. Only the ones we install are checked.
    SELECT string_agg(t, ', ') INTO v_missing
      FROM unnest(ARRAY['flock_movements_sync_insert',
                        'flock_movements_sync_update',
                        'flock_movements_tombstone',
                        'flock_movements_updated_at',
                        'trg_update_flock_count_movements',
                        'trg_validate_flock_movements',
                        'trg_guard_flock_movement_user_change']) AS t
     WHERE NOT EXISTS (SELECT 1 FROM pg_trigger
                        WHERE tgrelid = 'public.flock_movements'::regclass
                          AND tgname = t AND NOT tgisinternal);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION
            'FAIL: missing triggers on flock_movements: %. Present: %',
            v_missing,
            (SELECT COALESCE(string_agg(tgname, ', ' ORDER BY tgname), 'none')
               FROM pg_trigger
              WHERE tgrelid = 'public.flock_movements'::regclass
                AND NOT tgisinternal);
    END IF;

    RAISE NOTICE 'OK: W0.1 verified - flock_movements + sync_table_registry present';
END;
$$;

-- ── Triggers ──────────────────────────────────────────────────────────────
-- Names below are the ONES ALREADY IN PRODUCTION (json_output.txt), so this
-- migration re-creates exactly what was lost and adds only what is missing.
--   production: flock_movements_sync_insert / _sync_update / _tombstone
--               flock_movements_updated_at
--               trg_update_flock_count_movements
--   MISSING in production: the farm/flock consistency guard (see below).

-- populate_sync_changes: enqueue the row into sync_changes after every write.
-- Split per-operation because the sync layer wants separate statements.
DROP TRIGGER IF EXISTS flock_movements_sync_insert ON public.flock_movements;
CREATE TRIGGER flock_movements_sync_insert
    AFTER INSERT ON public.flock_movements
    FOR EACH ROW EXECUTE FUNCTION public.populate_sync_changes();

DROP TRIGGER IF EXISTS flock_movements_sync_update ON public.flock_movements;
CREATE TRIGGER flock_movements_sync_update
    AFTER UPDATE ON public.flock_movements
    FOR EACH ROW EXECUTE FUNCTION public.populate_sync_changes();

-- sync_tombstone_after_delete: a deleted row must reach other devices as a
-- tombstone, otherwise a device that never saw the row can never delete it.
DROP TRIGGER IF EXISTS flock_movements_tombstone ON public.flock_movements;
CREATE TRIGGER flock_movements_tombstone
    AFTER DELETE ON public.flock_movements
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

-- update_updated_at_column: standard maintain-column trigger.
DROP TRIGGER IF EXISTS flock_movements_updated_at ON public.flock_movements;
CREATE TRIGGER flock_movements_updated_at
    BEFORE UPDATE ON public.flock_movements
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- update_flock_count_from_movements: keep flocks.current_count in sync with
-- the movement ledger. This is what makes `depleted` flocks reachable.
DROP TRIGGER IF EXISTS trg_update_flock_count_movements
    ON public.flock_movements;
CREATE TRIGGER trg_update_flock_count_movements
    AFTER INSERT OR UPDATE OR DELETE ON public.flock_movements
    FOR EACH ROW EXECUTE FUNCTION public.update_flock_count_from_movements();

-- ── worker_id FK: why ON DELETE SET NULL and not ON DELETE RESTRICT ──────
-- A movement is a historical fact: "500 birds were added on this date by
-- this worker". Blocking the deletion of a user account just because they
-- appear in history would trap the farm owner -- the account could never
-- be removed without falsifying the ledger. SET NULL frees the account and
-- keeps the movement intact; attribution is lost, the record is not.
--
-- This differs from farm_id / flock_id, which stay ON DELETE RESTRICT:
-- those are LIVE accounting entities. Deleting them would orphan money.

-- guard_worker_same_farm()
-- Membership is read from user_farms (the many-to-many), NOT from
-- users.farm_id: a worker may serve several farms and users.farm_id only
-- records the single ACTIVE one, so checking that column would reject
-- perfectly valid attributions.
--
-- SECURITY DEFINER because the guard queries user_farms, which has its own
-- RLS; without it the check would see zero rows for an ordinary worker and
-- silently pass. search_path is pinned for the usual definer footgun.
CREATE OR REPLACE FUNCTION public.guard_worker_same_farm()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_farms uuid[];
BEGIN
    IF NEW.worker_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- No membership rows at all means the user_id is not a real account.
    SELECT array_agg(farm_id) INTO v_user_farms
      FROM public.user_farms
     WHERE user_id = NEW.worker_id;

    IF v_user_farms IS NULL THEN
        RAISE EXCEPTION 'العامل غير موجود: %', NEW.worker_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF NOT (NEW.farm_id = ANY (v_user_farms)) THEN
        RAISE EXCEPTION 'العامل لا ينتمي لهذه المزرعة'
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    RETURN NEW;
END;
$$;

-- trg_guard_flock_movement_user_change
-- A movement may only be attributed to a worker who belongs to the same
-- farm. Otherwise "who recorded this?" could resolve to someone from a
-- different farm entirely, which breaks both accountability and the
-- per-farm reports.
DROP TRIGGER IF EXISTS trg_guard_flock_movement_user_change
    ON public.flock_movements;
CREATE TRIGGER trg_guard_flock_movement_user_change
    BEFORE INSERT OR UPDATE OF worker_id, farm_id ON public.flock_movements
    FOR EACH ROW EXECUTE FUNCTION public.guard_worker_same_farm();

-- ── PART OF M5, DONE EARLY ───────────────────────────────────────────────
-- validate_flock_farm() is attached to egg_production, mortality,
-- feed_consumption, medications and opening_balances. Three more tables
-- own a flock_id but carried no such guard, so a row could name a flock
-- belonging to a DIFFERENT farm and still be accepted -- exactly the
-- "wrong linking" the spec forbids (principle 5). These two are closed
-- here because the function already exists and needs no change.
--
-- feed_received is included in this migration rather than in W1/M2 so that
-- the flock_farm guard lives in exactly one place.

DROP TRIGGER IF EXISTS trg_validate_flock_dispatch ON public.egg_dispatch;
CREATE TRIGGER trg_validate_flock_dispatch
    BEFORE INSERT OR UPDATE ON public.egg_dispatch
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_feed_recv ON public.feed_received;
CREATE TRIGGER trg_validate_flock_feed_recv
    BEFORE INSERT OR UPDATE ON public.feed_received
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

-- ── NEW GUARD (was absent in production) ──────────────────────────────────
-- Principle 5/6 of the spec: no wrong linking, ever. Without this trigger a
-- movement could name a flock belonging to ANOTHER farm and still be
-- accepted -- validate_flock_farm() is the project's existing guard and is
-- reused verbatim, exactly as init.sql does for egg_production/mortality/
-- feed_consumption/medications/opening_balances. It no-ops when
-- flock_id IS NULL; here flock_id is NOT NULL, so the guard always applies.
DROP TRIGGER IF EXISTS trg_validate_flock_movements
    ON public.flock_movements;
CREATE TRIGGER trg_validate_flock_movements
    BEFORE INSERT OR UPDATE ON public.flock_movements
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

-- ── RLS ───────────────────────────────────────────────────────────────────
-- Production names are `*_select` (not `*_read`) for this table; kept as-is.
ALTER TABLE public.flock_movements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS flock_movements_select ON public.flock_movements;
CREATE POLICY flock_movements_select ON public.flock_movements
    FOR SELECT TO authenticated
    USING (public.user_has_farm_access(farm_id));

DROP POLICY IF EXISTS flock_movements_insert ON public.flock_movements;
CREATE POLICY flock_movements_insert ON public.flock_movements
    FOR INSERT TO authenticated
    WITH CHECK (public.user_has_farm_access(farm_id));

DROP POLICY IF EXISTS flock_movements_update ON public.flock_movements;
CREATE POLICY flock_movements_update ON public.flock_movements
    FOR UPDATE TO authenticated
    USING (public.user_manages_farm(farm_id))
    WITH CHECK (public.user_manages_farm(farm_id));

DROP POLICY IF EXISTS flock_movements_delete ON public.flock_movements;
CREATE POLICY flock_movements_delete ON public.flock_movements
    FOR DELETE TO authenticated
    USING (public.user_manages_farm(farm_id));
