-- ============================================================================
-- M1b — revenue.flock_id
-- ============================================================================
--  WHY
--    `revenue` had no way to say WHICH flock the money came from, so every
--    revenue row was farm-level by construction -- "what did this flock earn?"
--    had no answer, and a flock's P&L could only ever show its costs.
--
--    This column makes revenue symmetrical with expenses.flock_id (M1) and
--    encodes the same rule (see docs/ACCOUNTING_RULES.md):
--        flock_id SET   -> DIRECT revenue, counts toward that flock's P&L
--        flock_id NULL  -> FARM revenue (building, equipment, misc), never
--                          allocated to a flock
--    Egg sales and live-chicken sales are the direct cases; selling an old
--    coop is a farm case.
--
--  DATA
--    Existing rows are not touched. The column is nullable with no default,
--    so every existing revenue row is classified as farm revenue. That is the
--    honest default: attributing historical money to a specific flock would
--    be a guess, and a wrong guess in an accounting system is worse than a
--    blank.
--
--  IDEMPOTENT. RE-RUN SAFE. NO DATA IS MODIFIED.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── the column ─────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                     AND table_name = 'revenue'
                     AND column_name = 'flock_id') THEN
        -- ON DELETE RESTRICT, deliberately: revenue is a financial record
        -- that belongs to a real flock. Deleting the flock must be refused,
        -- not silently strip the flock reference and orphan the money.
        -- Mirrors expenses.flock_id (M1).
        ALTER TABLE public.revenue
            ADD COLUMN flock_id uuid
            REFERENCES public.flocks(id) ON DELETE RESTRICT;
    END IF;
END;
$$;

COMMENT ON COLUMN public.revenue.flock_id IS
    'SET = direct revenue (counts in the flock P&L). NULL = farm-level '
    'revenue (building, equipment, misc), never allocated to a flock.';

-- ── indexes ────────────────────────────────────────────────────────────────
-- Composite on (farm_id, flock_id): every flock-revenue query filters by farm
-- first (RLS pushes farm_id into every predicate) and then by flock, so the
-- leading column must be farm_id or the planner cannot use the index for the
-- scoped lookup.
CREATE INDEX IF NOT EXISTS idx_revenue_farm_flock
    ON public.revenue (farm_id, flock_id);

-- Partial index for the common report: "show me only the direct revenue".
-- Direct rows are the minority (most revenue is farm-level), so indexing the
-- NULL majority would waste space for no benefit.
CREATE INDEX IF NOT EXISTS idx_revenue_flock_direct
    ON public.revenue (farm_id, flock_id)
    WHERE flock_id IS NOT NULL;

-- ── consistency guard ─────────────────────────────────────────────────────
-- Reuses validate_flock_farm() verbatim, the same helper init.sql attaches to
-- egg_production / mortality / feed_consumption / medications / opening_balances
-- and M1 attaches to expenses. It raises when flocks.farm_id <> NEW.farm_id,
-- which is the "wrong linking" the spec forbids (principle 5).
--
-- It returns NEW early when flock_id IS NULL, which is exactly what is wanted
-- here: farm-level revenue has no flock to check, so the guard must not reject
-- it.
DROP TRIGGER IF EXISTS trg_validate_flock_revenue ON public.revenue;
CREATE TRIGGER trg_validate_flock_revenue
    BEFORE INSERT OR UPDATE ON public.revenue
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

-- RLS is intentionally UNCHANGED. revenue is already manager/admin scoped
-- (M8, 20261002000000); adding a column cannot weaken it, and rewriting the
-- policies here would create a second source of truth.

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $$
DECLARE
    v_type text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                     AND table_name = 'revenue'
                     AND column_name = 'flock_id') THEN
        RAISE EXCEPTION 'FAIL: revenue.flock_id was not created';
    END IF;

    -- It must stay NULLABLE. A NOT NULL column would make it impossible to
    -- record farm-level revenue (a sold coop), i.e. it would break the rule
    -- that NULL means "farm-level", not "missing".
    SELECT is_nullable INTO v_type
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'revenue'
       AND column_name = 'flock_id';
    IF v_type <> 'YES' THEN
        RAISE EXCEPTION 'FAIL: revenue.flock_id must stay nullable, got %', v_type;
    END IF;

    SELECT format_type(a.atttypid, a.atttypmod) INTO v_type
      FROM pg_attribute a
     WHERE a.attrelid = 'public.revenue'::regclass
       AND a.attname = 'flock_id';
    IF v_type <> 'uuid' THEN
        RAISE EXCEPTION 'FAIL: revenue.flock_id must be uuid, got %', v_type;
    END IF;

    -- ON DELETE RESTRICT must be in force, or a flock could be deleted while
    -- revenue still points at it and the money would be orphaned silently.
    -- confdeltype 'r' = RESTRICT, 'a' = NO ACTION, 'c' = CASCADE.
    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint c
          JOIN pg_attribute a
            ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
         WHERE c.conrelid = 'public.revenue'::regclass
           AND c.contype = 'f'
           AND a.attname = 'flock_id'
           AND c.confdeltype = 'r'
    ) THEN
        RAISE EXCEPTION
            'FAIL: revenue.flock_id FK must be ON DELETE RESTRICT';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_indexes
                   WHERE schemaname = 'public'
                     AND tablename = 'revenue'
                     AND indexname = 'idx_revenue_farm_flock') THEN
        RAISE EXCEPTION 'FAIL: idx_revenue_farm_flock missing';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_indexes
                   WHERE schemaname = 'public'
                     AND tablename = 'revenue'
                     AND indexname = 'idx_revenue_flock_direct') THEN
        RAISE EXCEPTION 'FAIL: idx_revenue_flock_direct missing';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                   WHERE tgrelid = 'public.revenue'::regclass
                     AND tgname = 'trg_validate_flock_revenue'
                     AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FAIL: trg_validate_flock_revenue not installed';
    END IF;

    RAISE NOTICE
        'OK: M1b verified - revenue.flock_id is a nullable uuid FK with ON '
        'DELETE RESTRICT, indexed, and guarded.';
END;
$$;
