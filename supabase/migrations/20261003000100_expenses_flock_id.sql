-- ============================================================================
-- M1 — expenses.flock_id
-- ============================================================================
--  WHY
--    `expenses` had no way to say WHICH flock an expense belongs to. Every
--    expense was farm-level by construction, so "what does this flock cost?"
--    had no answer, and FlockPerformance.estimatedCost had to fake one by
--    multiplying feed kilos by the price of an egg.
--
--    The rule this column encodes (see docs/ACCOUNTING_RULES.md):
--        flock_id SET   -> DIRECT cost, counts toward that flock's P&L
--        flock_id NULL  -> FARM cost, never allocated to any flock
--    Salaries are always NULL (paid by the farm, not by a bird).
--
--  DATA
--    Existing rows are not touched. The column is nullable with no default,
--    so every existing expense is classified as a farm expense. That is the
--    correct default: allocating historical money to a specific flock would
--    be a guess, and a wrong guess in an accounting system is worse than an
--    honest blank.
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
                     AND table_name = 'expenses'
                     AND column_name = 'flock_id') THEN
        -- ON DELETE RESTRICT, deliberately: an expense is a financial record
        -- that belongs to a real flock. Deleting the flock must be refused,
        -- not silently strip the flock reference and orphan the money.
        -- (Contrast worker_id on flock_movements, which is SET NULL because a
        -- person's attribution is not a financial entity.)
        ALTER TABLE public.expenses
            ADD COLUMN flock_id uuid
            REFERENCES public.flocks(id) ON DELETE RESTRICT;
    END IF;
END;
$$;

COMMENT ON COLUMN public.expenses.flock_id IS
    'SET = direct flock cost (counts in flock P&L). NULL = farm-level cost '
    '(salaries, overhead), never allocated to a flock.';

-- ── index ──────────────────────────────────────────────────────────────────
-- Composite on (farm_id, flock_id) because every flock-cost query filters by
-- farm first (RLS pushes farm_id into every predicate) and then by flock.
-- A single-column index on flock_id alone would be useless here: the RLS
-- predicate already narrows to one farm, so the leading column must be
-- farm_id or the planner cannot use the index for the scoped lookup.
CREATE INDEX IF NOT EXISTS idx_expenses_farm_flock
    ON public.expenses (farm_id, flock_id);

-- Partial index for the common report: "show me only the direct costs".
-- Costs are the minority of rows once salaries are present, so indexing the
-- NULL majority would waste space and slow every scan for no benefit.
CREATE INDEX IF NOT EXISTS idx_expenses_flock_direct
    ON public.expenses (farm_id, flock_id)
    WHERE flock_id IS NOT NULL;

-- ── consistency guard ─────────────────────────────────────────────────────
-- Reuses validate_flock_farm() verbatim, the same helper init.sql already
-- attaches to egg_production / mortality / feed_consumption / medications /
-- opening_balances. It raises when flocks.farm_id <> NEW.farm_id, which is
-- exactly the "wrong linking" the spec forbids (principle 5).
--
-- It returns NEW early when flock_id IS NULL, which is precisely the wanted
-- behaviour here: a farm-level expense has no flock to check, so the guard
-- must not reject salaries.
DROP TRIGGER IF EXISTS trg_validate_flock_expenses ON public.expenses;
CREATE TRIGGER trg_validate_flock_expenses
    BEFORE INSERT OR UPDATE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

-- RLS is intentionally UNCHANGED. The expenses policies are already
-- manager/admin scoped; adding a column cannot weaken them, and rewriting
-- them here would create a second source of truth. W2/M8 hardens them
-- further, in its own migration.

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
                     AND table_name = 'expenses'
                     AND column_name = 'flock_id') THEN
        RAISE EXCEPTION 'FAIL: expenses.flock_id was not created';
    END IF;

    -- It must stay NULLABLE. A NOT NULL column would make it impossible to
    -- record a farm-level expense, i.e. it would break salaries outright.
    SELECT is_nullable INTO v_type
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'expenses'
       AND column_name = 'flock_id';
    IF v_type <> 'YES' THEN
        RAISE EXCEPTION 'FAIL: expenses.flock_id must stay nullable, got %', v_type;
    END IF;

    SELECT format_type(a.atttypid, a.atttypmod) INTO v_type
      FROM pg_attribute a
     WHERE a.attrelid = 'public.expenses'::regclass
       AND a.attname = 'flock_id';
    IF v_type <> 'uuid' THEN
        RAISE EXCEPTION 'FAIL: expenses.flock_id must be uuid, got %', v_type;
    END IF;

    -- ON DELETE RESTRICT must be in force, or a flock could be deleted while
    -- expenses still point at it and the money would be orphaned silently.
    -- confdeltype 'r' = RESTRICT, 'a' = NO ACTION, 'c' = CASCADE.
    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint c
          JOIN pg_attribute a
            ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
         WHERE c.conrelid = 'public.expenses'::regclass
           AND c.contype = 'f'
           AND a.attname = 'flock_id'
           AND c.confdeltype = 'r'
    ) THEN
        RAISE EXCEPTION
            'FAIL: expenses.flock_id FK must be ON DELETE RESTRICT';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_indexes
                   WHERE schemaname = 'public'
                     AND tablename = 'expenses'
                     AND indexname = 'idx_expenses_farm_flock') THEN
        RAISE EXCEPTION 'FAIL: idx_expenses_farm_flock missing';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                   WHERE tgrelid = 'public.expenses'::regclass
                     AND tgname = 'trg_validate_flock_expenses'
                     AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FAIL: trg_validate_flock_expenses not installed';
    END IF;

    RAISE NOTICE
        'OK: M1 verified - expenses.flock_id is a nullable uuid FK with ON '
        'DELETE RESTRICT, indexed, and guarded.';
END;
$$;
