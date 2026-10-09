-- ============================================================================
-- M17 ROLLBACK — remove opening_balances.opening_feed_received_kg
-- ============================================================================
--  To undo M17, run THIS file:
--      psql -f supabase/migrations/20261003001601_rollback_opening_feed_received.sql
--
--  ⚠ WHAT IT DESTROYS
--    DROP COLUMN removes every cumulative "feed received before tracking"
--    amount entered since M17 was applied. The derived opening stock
--
--        opening_feed_stock = opening_feed_received_kg − feed_consumed_kg
--
--    silently reverts to the pre-M17 narrative (stock was not derivable
--    from the DB alone). NULL is untouched (the field was simply never
--    entered); any non-NULL amount is lost.
--
--    Scope guard: refuses to run while any row still carries a non-NULL
--    opening_feed_received_kg, so an accidental run cannot quietly discard
--    entered data. Export it first if the value matters:
--        SELECT flock_id, opening_feed_received_kg
--          FROM opening_balances
--         WHERE opening_feed_received_kg IS NOT NULL;
--
--  IDEMPOTENT. RE-RUN SAFE.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── scope guard ────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_entered bigint;
    v_total   numeric;
BEGIN
    -- the column may not exist at all if M17 never ran; check before selecting.
    IF to_regclass('public.opening_balances') IS NOT NULL
       AND EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public'
                      AND table_name = 'opening_balances'
                      AND column_name = 'opening_feed_received_kg') THEN
        SELECT count(*), COALESCE(sum(opening_feed_received_kg), 0)
          INTO v_entered, v_total
          FROM public.opening_balances
         WHERE opening_feed_received_kg IS NOT NULL;

        IF v_entered > 0 THEN
            RAISE EXCEPTION
                'ABORT: % opening balance(s) carry opening_feed_received_kg '
                'totalling %. Entered data would be destroyed. Export it, or '
                'null out the column yourself once you have accepted the loss.',
                v_entered, v_total;
        END IF;
    END IF;

    RAISE NOTICE 'scope check passed: no opening balance carries a received amount';
END;
$$;

-- ── drop ───────────────────────────────────────────────────────────────────
-- DROP COLUMN also drops the CHECK constraint it owns, so no separate
-- DROP CONSTRAINT is needed. IF EXISTS keeps a re-run a no-op.
ALTER TABLE public.opening_balances
    DROP COLUMN IF EXISTS opening_feed_received_kg;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = 'opening_balances'
                 AND column_name = 'opening_feed_received_kg') THEN
        RAISE EXCEPTION 'FAIL: opening_feed_received_kg still present after rollback';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_constraint
               WHERE conname = 'opening_balances_opening_feed_received_kg_check'
                 AND conrelid = 'public.opening_balances'::regclass) THEN
        RAISE EXCEPTION 'FAIL: M17 CHECK constraint outlived the column';
    END IF;

    RAISE NOTICE 'OK: M17 rolled back cleanly - opening_feed_received_kg is gone';
END;
$$;