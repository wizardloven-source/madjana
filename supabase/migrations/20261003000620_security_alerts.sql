-- ============================================================================
-- M6c: security_alerts — RLS + grants + admin surface
-- ============================================================================
-- WHY
--   M6b created security_alerts minimal (no RLS, no policies, no grants) so the
--   20-hit throttle ladder had somewhere to record escalations. That made the
--   table readable by NOTHING in the app (safe) but also by NOTHING useful: a
--   system admin had no sanctioned way to list, acknowledge or resolve alerts,
--   and a non-admin could not even prove that they COULD NOT see them. M6c adds
--   the permanent shape:
--
--     * RLS on, with a single FOR ALL policy that admits ONLY is_system_admin().
--       No worker policy. No manager policy. System admin only.
--     * Table grants: REVOKE ALL from PUBLIC/anon/authenticated, then
--       SELECT/INSERT/UPDATE to authenticated. RLS still decides which rows a
--       given authenticated session may actually move (none unless system_admin).
--     * Three SECURITY DEFINER admin functions (granted to authenticated, the
--       API role that carries the claim; each re-checks is_system_admin()):
--       get_unresolved_security_alerts(), acknowledge_security_alert(uuid),
--       resolve_security_alert(uuid).
--
-- SCOPE (nothing outside this is touched)
--   * ALTERs the existing security_alerts (M6b object) -- DOES NOT recreate it.
--   * DOES NOT recreate record_security_alert (M6b writer stays as-is).
--   * adds the audit columns the acknowledge/resolve functions need:
--     acknowledged_at, acknowledged_by, resolved_at, resolved_by
--   * enables RLS + installs the single admin-only policy.
--   * installs the three admin surface functions.
--
-- SECURITY NOTES
--   * every NEW function is SECURITY DEFINER, search_path pinned, REVOKEd from
--     PUBLIC and anon (a fresh function EXECs to PUBLIC by default), granted to
--     authenticated, and re-gates the caller with is_system_admin().
--   * the policy names is_system_admin() ONLY -- nothing else can read or write
--     a row, so an authenticated worker/manager session sees an empty table and
--     cannot insert (RLS returns 0 rows / refuses the write, even though the
--     GRANT exists).
--   * no production data touched; re-runs cleanly (IRREVERSIBLE only as guard:
--     idem → guarded DROP POLICY + ADD COLUMN IF NOT EXISTS).
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) audit columns for acknowledge / resolve (M6b did not create these) ────
ALTER TABLE public.security_alerts ADD COLUMN IF NOT EXISTS acknowledged_at timestamptz;
ALTER TABLE public.security_alerts ADD COLUMN IF NOT EXISTS acknowledged_by uuid;
ALTER TABLE public.security_alerts ADD COLUMN IF NOT EXISTS resolved_at     timestamptz;
ALTER TABLE public.security_alerts ADD COLUMN IF NOT EXISTS resolved_by     uuid;

-- ── 2) RLS: system admin only ────────────────────────────────────────────────
ALTER TABLE public.security_alerts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS security_alerts_admin_all ON public.security_alerts;
CREATE POLICY security_alerts_admin_all ON public.security_alerts
    FOR ALL
    USING (is_system_admin())
    WITH CHECK (is_system_admin());

-- ── 3) table grants: authenticated gets SELECT/INSERT/UPDATE, RLS gates rows ──
REVOKE ALL ON TABLE security_alerts FROM PUBLIC;
REVOKE ALL ON TABLE security_alerts FROM anon;
REVOKE ALL ON TABLE security_alerts FROM authenticated;

GRANT SELECT, INSERT, UPDATE ON TABLE security_alerts TO authenticated;

-- ── 4) admin surface ─────────────────────────────────────────────────────────
-- 4a) list the open cases, newest first (security ops triage order)
CREATE OR REPLACE FUNCTION public.get_unresolved_security_alerts()
RETURNS SETOF security_alerts
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6c$
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'غير مصرح: هذه البيانات لـ system_admin فقط';
    END IF;

    RETURN QUERY
        SELECT * FROM public.security_alerts
         WHERE resolved_at IS NULL
         ORDER BY created_at DESC;
END;
$m6c$;

REVOKE EXECUTE ON FUNCTION public.get_unresolved_security_alerts() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_unresolved_security_alerts() TO authenticated;

-- 4b) acknowledge: stamp acknowledged_at + acknowledged_by, do NOT resolve
CREATE OR REPLACE FUNCTION public.acknowledge_security_alert(p_alert_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6c$
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'غير مصرح: هذه البيانات لـ system_admin فقط';
    END IF;

    IF p_alert_id IS NULL THEN
        RAISE EXCEPTION 'معرف تنبيه مطلوب';
    END IF;

    UPDATE public.security_alerts
       SET acknowledged_at = NOW(),
           acknowledged_by = auth.uid()
     WHERE id = p_alert_id;
END;
$m6c$;

REVOKE EXECUTE ON FUNCTION public.acknowledge_security_alert(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.acknowledge_security_alert(uuid) TO authenticated;

-- 4c) resolve: stamp resolved_at + resolved_by
CREATE OR REPLACE FUNCTION public.resolve_security_alert(p_alert_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6c$
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'غير مصرح: هذه البيانات لـ system_admin فقط';
    END IF;

    IF p_alert_id IS NULL THEN
        RAISE EXCEPTION 'معرف تنبيه مطلوب';
    END IF;

    UPDATE public.security_alerts
       SET resolved_at = NOW(),
           resolved_by = auth.uid()
     WHERE id = p_alert_id;
END;
$m6c$;

REVOKE EXECUTE ON FUNCTION public.resolve_security_alert(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.resolve_security_alert(uuid) TO authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m6c$
DECLARE
    v_n int;
    v_rls boolean;
    v_policy int;
BEGIN
    -- table is RLS-enabled
    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'security_alerts';
    IF NOT v_rls THEN
        RAISE EXCEPTION 'FAIL: security_alerts RLS not enabled';
    END IF;

    -- exactly the admin-only policy, gate on is_system_admin
    SELECT count(*) INTO v_policy
      FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'security_alerts'
       AND policyname = 'security_alerts_admin_all';
    IF v_policy <> 1 THEN
        RAISE EXCEPTION 'FAIL: security_alerts_admin_all policy missing';
    END IF;

    -- table grants: anon nothing, authenticated the trio
    IF has_table_privilege('anon', 'security_alerts', 'SELECT')
       OR has_table_privilege('anon', 'security_alerts', 'INSERT')
       OR has_table_privilege('anon', 'security_alerts', 'UPDATE') THEN
        RAISE EXCEPTION 'FAIL: anon can touch security_alerts';
    END IF;
    IF NOT has_table_privilege('authenticated', 'security_alerts', 'SELECT')
       OR NOT has_table_privilege('authenticated', 'security_alerts', 'INSERT')
       OR NOT has_table_privilege('authenticated', 'security_alerts', 'UPDATE') THEN
        RAISE EXCEPTION 'FAIL: authenticated lost SELECT/INSERT/UPDATE on security_alerts';
    END IF;

    -- audit columns present
    SELECT count(*) INTO v_n
      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'security_alerts'
       AND a.attname IN ('acknowledged_at','acknowledged_by','resolved_at','resolved_by')
       AND NOT a.attisdropped;
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FAIL: audit columns incomplete (found %)', v_n;
    END IF;

    -- the three functions, SECURITY DEFINER, secured grants
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname = 'get_unresolved_security_alerts' AND prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: get_unresolved_security_alerts not SECURITY DEFINER';
    END IF;
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname = 'acknowledge_security_alert' AND prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: acknowledge_security_alert not SECURITY DEFINER';
    END IF;
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname = 'resolve_security_alert' AND prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: resolve_security_alert not SECURITY DEFINER';
    END IF;

    IF has_function_privilege('anon', 'public.get_unresolved_security_alerts()', 'EXECUTE')
       OR has_function_privilege('anon', 'public.acknowledge_security_alert(uuid)', 'EXECUTE')
       OR has_function_privilege('anon', 'public.resolve_security_alert(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: anon can call the M6c admin functions';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.get_unresolved_security_alerts()', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.acknowledge_security_alert(uuid)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.resolve_security_alert(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: authenticated lost EXECUTE on the M6c admin functions';
    END IF;

    RAISE NOTICE 'OK: M6c verified - RLS admin-only, grants right, three admin functions live';
END;
$m6c$;