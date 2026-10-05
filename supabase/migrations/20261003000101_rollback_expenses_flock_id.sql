-- ============================================================================
-- M1 ROLLBACK — remove expenses.flock_id
-- ============================================================================
--  To undo M1, run THIS file:
--      psql -f supabase/migrations/20261003000101_rollback_expenses_flock_id.sql
--
--  ⚠ WHAT IT DESTROYS
--    DROP COLUMN removes every flock assignment made since M1 was applied.
--    A salary correctly recorded as flock_id = NULL is untouched; a direct
--    flock cost -- electricity, a medicine, a hired hand for one flock --
--    loses its attribution and reverts to a farm-level cost. Flock P&L will
--    silently go back to understating its own cost.
--
--    Scope guard: refuses to run while any expense still carries a non-NULL
--    flock_id, so an accidental run cannot quietly rewrite the books.
--    Confirm the loss is intended, or export the assignments first:
--        SELECT flock_id, count(*), sum(amount)
--          FROM expenses WHERE flock_id IS NOT NULL GROUP BY 1;
--
--  IDEMPOTENT. RE-RUN SAFE.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── scope guard ────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_assigned bigint;
    v_total     numeric;
BEGIN
    -- flock_id may not exist at all if M1 never ran; check before selecting.
    IF to_regclass('public.expenses') IS NOT NULL
       AND EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public'
                      AND table_name = 'expenses'
                      AND column_name = 'flock_id') THEN
        SELECT count(*), COALESCE(sum(amount), 0)
          INTO v_assigned, v_total
          FROM public.expenses
         WHERE flock_id IS NOT NULL;

        IF v_assigned > 0 THEN
            RAISE EXCEPTION
                'ABORT: % expenses carry a flock_id totalling %. Flock cost '
                'attribution would be destroyed. Export it, or null out the '
                'column yourself once you have accepted the loss.',
                v_assigned, v_total;
        END IF;
    END IF;

    RAISE NOTICE 'scope check passed: no expense carries a flock_id';
END;
$$;

-- ── drop ───────────────────────────────────────────────────────────────────
-- The trigger goes first: it references the column and would block the drop.
DROP TRIGGER IF EXISTS trg_validate_flock_expenses ON public.expenses;

-- The index goes before the column for the same reason.
DROP INDEX IF EXISTS public.idx_expenses_flock_direct;
DROP INDEX IF EXISTS public.idx_expenses_farm_flock;

-- DROP COLUMN also drops the FK constraint it owns, so no separate
-- DROP CONSTRAINT is needed. IF EXISTS keeps a re-run a no-op.
ALTER TABLE public.expenses
    DROP COLUMN IF EXISTS flock_id;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = 'expenses'
                 AND column_name = 'flock_id') THEN
        RAISE EXCEPTION 'FAIL: expenses.flock_id still present after rollback';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_indexes
               WHERE schemaname = 'public'
                 AND indexname LIKE 'idx_expenses_%flock%') THEN
        RAISE EXCEPTION 'FAIL: a flock index outlived the column';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_trigger
               WHERE tgrelid = 'public.expenses'::regclass
                 AND tgname = 'trg_validate_flock_expenses') THEN
        RAISE EXCEPTION 'FAIL: trg_validate_flock_expenses outlived the column';
    END IF;

    RAISE NOTICE 'OK: M1 rolled back cleanly - expenses.flock_id is gone';
END;
$$;
