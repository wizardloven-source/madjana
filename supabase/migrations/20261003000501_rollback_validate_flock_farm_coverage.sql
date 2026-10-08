-- ============================================================================
-- M5 ROLLBACK -- remove the guards M5 added
-- ============================================================================
--  Scope guard: drops ONLY what M5 introduces:
--      * trg_validate_flock_sa  (stock_adjustments had no flock guard before)
--      * trg_require_farm_id on the five tables + require_farm_id()
--      * the stray flocks trigger / index the earlier broken M5 left behind
--
--  NOT dropped here, on purpose:
--      * trg_validate_flock_dispatch / trg_validate_flock_feed_recv
--          owned by 20260927000000 (W0.1)
--      * trg_validate_flock_expenses
--          owned by 20261003000100 (M1)
--      * trg_validate_flock_med
--          owned by init.sql
--    M5 only RE-ASSERTS those four; dropping them here would strip
--    cross-farm protection that predates M5, and that is not M5's to take
--    away. Their own rollbacks own their removal.
--
--  IDEMPOTENT. RE-RUN SAFE. NO DATA IS MODIFIED.
-- ============================================================================

BEGIN;

DROP TRIGGER IF EXISTS trg_validate_flock_sa ON public.stock_adjustments;

DROP TRIGGER IF EXISTS trg_require_farm_id ON public.egg_dispatch;
DROP TRIGGER IF EXISTS trg_require_farm_id ON public.feed_received;
DROP TRIGGER IF EXISTS trg_require_farm_id ON public.stock_adjustments;
DROP TRIGGER IF EXISTS trg_require_farm_id ON public.expenses;
DROP TRIGGER IF EXISTS trg_require_farm_id ON public.medications;
DROP FUNCTION IF EXISTS public.require_farm_id();

-- debris from the earlier broken version of M5
DROP TRIGGER IF EXISTS trg_validate_flock_farm ON public.flocks;
DROP INDEX IF EXISTS public.idx_flocks_active;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_trigger
               WHERE tgname = 'trg_validate_flock_sa' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FAIL: trg_validate_flock_sa outlived the rollback';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_trigger
               WHERE tgname = 'trg_require_farm_id' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FAIL: trg_require_farm_id outlived the rollback';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'require_farm_id') THEN
        RAISE EXCEPTION 'FAIL: require_farm_id() outlived the rollback';
    END IF;

    -- the pre-M5 guards must survive: they belong to other migrations
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                   WHERE tgrelid = 'public.egg_dispatch'::regclass
                     AND tgname = 'trg_validate_flock_dispatch' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FAIL: egg_dispatch lost a guard it owned before M5';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                   WHERE tgrelid = 'public.expenses'::regclass
                     AND tgname = 'trg_validate_flock_expenses' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FAIL: expenses lost a guard it owned before M5';
    END IF;

    RAISE NOTICE 'OK: M5 rolled back cleanly - only M5''s own guards are gone';
END;
$$;