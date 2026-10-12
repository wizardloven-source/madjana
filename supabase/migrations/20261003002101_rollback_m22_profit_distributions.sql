-- ============================================================================
-- M22 ROLLBACK — undo profit_distributions + profit_distribution_details
-- ============================================================================
--  To undo M22, run THIS file:
--      psql -f supabase/migrations/20261003002101_rollback_m22_profit_distributions.sql
--
--  ⚠ WHAT IT DESTROYS
--    DROP TABLE removes every profit period and every per-partner line entered
--    since M22 was applied. There is no backup inside the database.
--
--  Scope guard: refuses to run while either table holds any row, so an
--  accidental run cannot quietly discard the ledger. Export first:
--      SELECT * FROM profit_distributions;
--      SELECT * FROM profit_distribution_details;
--
--  IDEMPOTENT. RE-RUN SAFE. Order matters: details first (it references the
--  header and public.farms/partners), then the header.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── scope guard ──────────────────────────────────────────────────────────────
DO $m22rb$
DECLARE
    v_d bigint := 0;
    v_h bigint := 0;
BEGIN
    IF to_regclass('public.profit_distribution_details') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM public.profit_distribution_details' INTO v_d;
    END IF;
    IF to_regclass('public.profit_distributions') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM public.profit_distributions' INTO v_h;
    END IF;

    IF v_d > 0 OR v_h > 0 THEN
        RAISE EXCEPTION
            'ABORT: profit_distribution_details has % row(s), profit_distributions has % row(s). '
            'Dropping would destroy the profit ledger. Export it first, or delete '
            'the rows yourself once you have accepted the loss.',
            v_d, v_h;
    END IF;

    RAISE NOTICE 'scope check passed: W6 profit tables are empty';
END;
$m22rb$;

-- ── drop ─────────────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_pdd_updated_at ON public.profit_distribution_details;
DROP TRIGGER IF EXISTS trg_profit_distributions_updated_at ON public.profit_distributions;

DROP TABLE IF EXISTS public.profit_distribution_details;
DROP TABLE IF EXISTS public.profit_distributions;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m22rb$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname IN ('profit_distributions', 'profit_distribution_details');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: W6 profit tables survived rollback';
    END IF;

    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE NOT tgisinternal
       AND tgname IN ('trg_profit_distributions_updated_at', 'trg_pdd_updated_at');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: W6 profit updated_at triggers survived rollback';
    END IF;

    RAISE NOTICE 'OK: M22 rollback verified - profit_distributions + details removed';
END;
$m22rb$;
