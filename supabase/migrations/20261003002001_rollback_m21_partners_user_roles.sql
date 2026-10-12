-- ============================================================================
-- M21 ROLLBACK — undo partners + user_roles
-- ============================================================================
--  To undo M21, run THIS file:
--      psql -f supabase/migrations/20261003002001_rollback_m21_partners_user_roles.sql
--
--  ⚠ WHAT IT DESTROYS
--    DROP TABLE removes every partner profile and every dynamic role grant
--    entered since M21 was applied. There is no backup inside the database.
--
--  Scope guard: refuses to run while partners or user_roles holds any row, so
--  an accidental run cannot quietly discard entered data. Export first:
--      SELECT * FROM partners;
--      SELECT * FROM user_roles;
--
--  IDEMPOTENT. RE-RUN SAFE. Order matters: user_roles is dropped first (it is
--  the one that references other entities); both are independent of each other.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── scope guard ──────────────────────────────────────────────────────────────
DO $m21rb$
DECLARE
    v_p bigint := 0;
    v_u bigint := 0;
BEGIN
    IF to_regclass('public.partners') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM public.partners' INTO v_p;
    END IF;
    IF to_regclass('public.user_roles') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM public.user_roles' INTO v_u;
    END IF;

    IF v_p > 0 OR v_u > 0 THEN
        RAISE EXCEPTION
            'ABORT: partners has % row(s), user_roles has % row(s). '
            'Dropping would destroy entered data. Export it first, or delete '
            'the rows yourself once you have accepted the loss.',
            v_p, v_u;
    END IF;

    RAISE NOTICE 'scope check passed: W6 tables are empty';
END;
$m21rb$;

-- ── drop ─────────────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_user_roles_updated_at ON public.user_roles;
DROP TRIGGER IF EXISTS trg_partners_updated_at ON public.partners;

DROP TABLE IF EXISTS public.user_roles;
DROP TABLE IF EXISTS public.partners;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m21rb$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('partners', 'user_roles');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: W6 base tables survived rollback';
    END IF;

    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE NOT tgisinternal
       AND tgname IN ('trg_partners_updated_at', 'trg_user_roles_updated_at');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: W6 updated_at triggers survived rollback';
    END IF;

    RAISE NOTICE 'OK: M21 rollback verified - partners + user_roles removed';
END;
$m21rb$;
