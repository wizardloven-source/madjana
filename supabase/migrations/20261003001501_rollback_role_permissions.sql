-- ============================================================================
-- M16 ROLLBACK — undo role_permissions / user_permissions / has_capability
--   Drop the function, then the tables (user_permissions first: it has no FK
--   to role_permissions, order is arbitrary; both drop cleanly).
-- ============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.has_capability(uuid, text, uuid);

DROP TABLE IF EXISTS public.user_permissions;
DROP TABLE IF EXISTS public.role_permissions;

COMMIT;

DO $m16rb$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_proc WHERE proname='has_capability';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: has_capability survived rollback';
    END IF;
    SELECT count(*) INTO v_n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relname IN ('role_permissions','user_permissions');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: permission tables survived rollback';
    END IF;
    RAISE NOTICE 'OK: M16 rollback verified - permission layer removed';
END;
$m16rb$;