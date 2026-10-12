-- ============================================================================
-- M23 ROLLBACK — undo partner_withdrawals + partner_audit
-- ============================================================================
--  To undo M23, run THIS file:
--      psql -f supabase/migrations/20261003002201_rollback_m23_partner_withdrawals_partner_audit.sql
--
--  ⚠ WHAT IT DESTROYS
--    DROP TABLE removes every withdrawal request AND the entire partner audit
--    trail entered since M23 was applied. There is no backup inside the
--    database.
--
--  Scope guard: refuses to run while either table holds any row, so an
--  accidental run cannot quietly discard money requests or the audit trail.
--  Export first:
--      SELECT * FROM partner_withdrawals;
--      SELECT * FROM partner_audit;
--
--  IDEMPOTENT. RE-RUN SAFE. Order: triggers, then tables (audit then
--  withdrawals), then the two guard functions.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── scope guard ──────────────────────────────────────────────────────────────
DO $m23rb$
DECLARE
    v_w bigint := 0;
    v_a bigint := 0;
BEGIN
    IF to_regclass('public.partner_withdrawals') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM public.partner_withdrawals' INTO v_w;
    END IF;
    IF to_regclass('public.partner_audit') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM public.partner_audit' INTO v_a;
    END IF;

    IF v_w > 0 OR v_a > 0 THEN
        RAISE EXCEPTION
            'ABORT: partner_withdrawals has % row(s), partner_audit has % row(s). '
            'Dropping would destroy withdrawal requests and the audit trail. '
            'Export them first, or delete the rows yourself once you have '
            'accepted the loss.',
            v_w, v_a;
    END IF;

    RAISE NOTICE 'scope check passed: W6 withdrawal/audit tables are empty';
END;
$m23rb$;

-- ── drop ─────────────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_partner_withdrawals_tombstone ON public.partner_withdrawals;
DROP TRIGGER IF EXISTS trg_partner_withdrawals_sync ON public.partner_withdrawals;
DROP TRIGGER IF EXISTS trg_partner_withdrawals_guard ON public.partner_withdrawals;
DROP TRIGGER IF EXISTS trg_partner_withdrawals_validate ON public.partner_withdrawals;
DROP TRIGGER IF EXISTS trg_partner_withdrawals_updated_at ON public.partner_withdrawals;

DROP TABLE IF EXISTS public.partner_audit;
DROP TABLE IF EXISTS public.partner_withdrawals;

DROP FUNCTION IF EXISTS public.guard_withdrawal_status();
DROP FUNCTION IF EXISTS public.validate_partner_withdrawal();
DROP FUNCTION IF EXISTS public.record_partner_audit(uuid, text, uuid, uuid, jsonb, jsonb, text, text, text);

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m23rb$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname IN ('partner_withdrawals', 'partner_audit');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: W6 withdrawal/audit tables survived rollback';
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('validate_partner_withdrawal', 'guard_withdrawal_status', 'record_partner_audit');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: W6 guard functions survived rollback';
    END IF;

    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE NOT tgisinternal
       AND tgname LIKE 'trg_partner_withdrawals%';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: W6 withdrawal/audit triggers survived rollback';
    END IF;

    RAISE NOTICE 'OK: M23 rollback verified - partner_withdrawals + partner_audit removed';
END;
$m23rb$;
