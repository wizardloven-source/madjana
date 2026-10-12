-- ============================================================================
-- M1b ROLLBACK — revenue.flock_id
-- ============================================================================
--  Removes exactly what 20261003000150_revenue_flock_id.sql added.
--
--  SCOPE GUARD
--    The rollback refuses to run while any revenue row carries a flock_id.
--    Dropping the column would silently erase a real attribution (money
--    pointed at a specific flock), turning a deliberate classification into
--    missing data. NULL out those rows explicitly first, or do not roll back.
--
--  IDEMPOTENT. RE-RUN SAFE. NO DATA IS MODIFIED when the guard passes.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '10s';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = 'revenue'
                 AND column_name = 'flock_id') THEN
        -- Scope guard: refuse while real attributions exist.
        IF EXISTS (SELECT 1 FROM public.revenue WHERE flock_id IS NOT NULL) THEN
            RAISE EXCEPTION
                'ABORT: cannot rollback - revenue rows with flock_id exist';
        END IF;

        DROP TRIGGER IF EXISTS trg_validate_flock_revenue ON public.revenue;
        DROP INDEX IF EXISTS public.idx_revenue_flock_direct;
        DROP INDEX IF EXISTS public.idx_revenue_farm_flock;
        ALTER TABLE public.revenue DROP COLUMN IF EXISTS flock_id;
    END IF;
END;
$$;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = 'revenue'
                 AND column_name = 'flock_id') THEN
        RAISE EXCEPTION 'FAIL: revenue.flock_id still present after rollback';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_trigger
               WHERE tgrelid = 'public.revenue'::regclass
                 AND tgname = 'trg_validate_flock_revenue'
                 AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FAIL: trg_validate_flock_revenue still installed';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_indexes
               WHERE schemaname = 'public'
                 AND tablename = 'revenue'
                 AND indexname IN ('idx_revenue_farm_flock',
                                   'idx_revenue_flock_direct')) THEN
        RAISE EXCEPTION 'FAIL: a revenue flock index survived the rollback';
    END IF;

    RAISE NOTICE 'OK: M1b rollback verified - revenue.flock_id removed.';
END;
$$;
