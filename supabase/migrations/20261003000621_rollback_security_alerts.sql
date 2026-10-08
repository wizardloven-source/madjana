-- ============================================================================
-- M6c rollback: security_alerts RLS + grants + admin surface
-- ============================================================================
-- WHY
--   Restores the pre-M6c state of security_alerts: RLS off, no admin-only
--   policy, no table grants for authenticated (the table becomes writable by
--   nothing again -- the M6b SECURITY DEFINER writer record_security_alert
--   still works, and API roles fall back to "cannot see or touch it").
--
-- SCOPE (nothing outside this is touched)
--   * drops get_unresolved_security_alerts(), acknowledge_security_alert(uuid),
--     resolve_security_alert(uuid)  [the three M6c functions]
--   * drops the security_alerts_admin_all policy
--   * disables row level security on security_alerts
--   * revokes the SELECT/INSERT/UPDATE grants M6c gave authenticated
--   * drops the four audit columns M6c added
--   Leaves record_security_alert() and the table itself (M6b objects) intact.
--
-- SECURITY NOTES
--   * Guarded: refuses while security_alerts still holds ANY row. DROPping the
--     policy would re-open the table to nothing (grants are being revoked too),
--     so rows are not at risk -- but an operator rolling back mid-incident
--     would lose the admin tooling that surfaces them. Review/open the alerts,
--     or empty the table, before rolling back.
--   * guard fails loudly (RAISE) rather than silently half-rolling back.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED (except by operator choice).
-- ============================================================================

BEGIN;

-- ── 1) scope guard ────────────────────────────────────────────────────────────
DO $m6c$
BEGIN
    IF to_regclass('public.security_alerts') IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.security_alerts) THEN
        RAISE EXCEPTION 'REFUSED: security_alerts يحتوي تنبيهات مسجلة — راجعها أو أفرغ الجدول قبل التراجع';
    END IF;
END;
$m6c$;

-- ── 2) drop the M6c admin surface ─────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.get_unresolved_security_alerts();
DROP FUNCTION IF EXISTS public.acknowledge_security_alert(uuid);
DROP FUNCTION IF EXISTS public.resolve_security_alert(uuid);

-- ── 3) policy + RLS off ───────────────────────────────────────────────────────
DROP POLICY IF EXISTS security_alerts_admin_all ON public.security_alerts;
ALTER TABLE public.security_alerts DISABLE ROW LEVEL SECURITY;

-- ── 4) grants back to zero (M6c's authenticated trio) ─────────────────────────
REVOKE SELECT, INSERT, UPDATE ON TABLE public.security_alerts FROM authenticated;

-- ── 5) audit columns back to M6b's shape ──────────────────────────────────────
ALTER TABLE public.security_alerts DROP COLUMN IF EXISTS acknowledged_at;
ALTER TABLE public.security_alerts DROP COLUMN IF EXISTS acknowledged_by;
ALTER TABLE public.security_alerts DROP COLUMN IF EXISTS resolved_at;
ALTER TABLE public.security_alerts DROP COLUMN IF EXISTS resolved_by;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m6c$
DECLARE
    v_rls boolean;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_unresolved_security_alerts')
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'acknowledge_security_alert')
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'resolve_security_alert') THEN
        RAISE EXCEPTION 'FAIL: M6c admin functions still present';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_policies
                WHERE schemaname = 'public' AND tablename = 'security_alerts'
                  AND policyname = 'security_alerts_admin_all') THEN
        RAISE EXCEPTION 'FAIL: security_alerts_admin_all policy still present';
    END IF;

    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'security_alerts';
    IF v_rls THEN
        RAISE EXCEPTION 'FAIL: security_alerts RLS still enabled';
    END IF;

    IF has_table_privilege('authenticated', 'security_alerts', 'SELECT')
       OR has_table_privilege('authenticated', 'security_alerts', 'INSERT')
       OR has_table_privilege('authenticated', 'security_alerts', 'UPDATE') THEN
        RAISE EXCEPTION 'FAIL: authenticated still holds M6c grants on security_alerts';
    END IF;

    RAISE NOTICE 'OK: M6c rolled back cleanly - admin surface gone, RLS off, grants revoked';
END;
$m6c$;