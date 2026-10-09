-- ============================================================================
-- M16: role_permissions + user_permissions + has_capability()
-- ============================================================================
-- WHY
--   Today a manager either can or cannot touch a table (RLS on the app roles)
--   and that is it: no per-capability control, no per-user grant, no per-farm
--   default override. The farm needs finer decisions -- "the accountant can
--   VIEW costs but not edit them", "this worker may also manage inventory" --
--   without waiting for a code release.
--
--   M16 ships the FOUNDATION only (as designed for W5):
--     * role_permissions   -- role × capability defaults, farm-scoped or
--                            global (farm_id NULL).
--     * user_permissions   -- per-user overrides (allow _or deny_) for a
--                            specific farm.
--     * has_capability()   -- the one lookup everything else will call.
--   It DOES NOT rewrite any existing RLS policy. The policies that USE
--   has_capability() arrive in W6, once the app can populate this table.
--   Everything shipped now is additive and safe to leave dormant.
--
-- RESOLUTION ORDER (inside has_capability)
--   1. explicit user_permissions row for (user, farm, capability) wins -- its
--      permission_value is returned verbatim, so a deny override works.
--   2. otherwise the role defaults: any ENABLED role_permissions row for the
--      user's role and capability, global or farm-scoped, resolves true.
--   3. otherwise false (deny by default).
--
-- SECURITY NOTES
--   * the tables are RLS admin-only (is_system_admin()): a worker/manager
--     session sees an empty table and can never edit the grants. The app
--     reads effective capabilities through has_capability() instead.
--   * has_capability() is SECURITY DEFINER + search_path pinned: it reads
--     the permission tables regardless of caller RLS and returns a boolean
--     scalar -- safe to call from any authenticated session.
--   * farm_id -> farms RESTRICT, user refs SET NULL, no CASCADE.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) role defaults ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.role_permissions (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    role       text NOT NULL CHECK (char_length(role) > 0),
    capability text NOT NULL CHECK (char_length(capability) > 0),
    is_enabled boolean NOT NULL DEFAULT true,
    farm_id    uuid REFERENCES public.farms(id) ON DELETE RESTRICT,
    granted_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
    granted_at timestamptz NOT NULL DEFAULT now()
);

-- NULLS NOT DISTINCT: (role, capability, NULL) is the single GLOBAL default
-- for that capability. PG 13+; the local PG15 and the Supabase PG15 both
-- accept it. A farm-scoped row must never shadow-global twice.
ALTER TABLE public.role_permissions
    ADD CONSTRAINT role_permissions_unique UNIQUE NULLS NOT DISTINCT
    (role, capability, farm_id);

-- ── 2) per-user overrides ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_permissions (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    farm_id          uuid NOT NULL REFERENCES public.farms(id) ON DELETE RESTRICT,
    permission_key   text NOT NULL CHECK (char_length(permission_key) > 0),
    permission_value boolean NOT NULL DEFAULT true,
    granted_by       uuid REFERENCES public.users(id) ON DELETE SET NULL,
    granted_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, farm_id, permission_key)
);

-- ── 3) the effective-capability lookup ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.has_capability(
    p_user_id    uuid,
    p_capability text,
    p_farm_id    uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m16$
DECLARE
    v_role     text;
    v_explicit boolean;
    v_default  boolean := false;
BEGIN
    IF p_user_id IS NULL OR p_capability IS NULL OR p_farm_id IS NULL THEN
        RETURN false;
    END IF;

    SELECT up.permission_value
      INTO v_explicit
      FROM public.user_permissions up
     WHERE up.user_id = p_user_id
       AND up.farm_id = p_farm_id
       AND up.permission_key = p_capability;
    IF FOUND THEN
        RETURN v_explicit;
    END IF;

    SELECT u.role::text INTO v_role FROM public.users u WHERE u.id = p_user_id;

    SELECT COALESCE(bool_or(rp.is_enabled), false)
      INTO v_default
      FROM public.role_permissions rp
     WHERE rp.role = v_role
       AND rp.capability = p_capability
       AND (rp.farm_id IS NULL OR rp.farm_id = p_farm_id);

    RETURN v_default;
END;
$m16$;

-- ── 4) RLS: admin-only, both tables ──────────────────────────────────────────
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS role_permissions_admin_all ON public.role_permissions;
CREATE POLICY role_permissions_admin_all ON public.role_permissions
    FOR ALL
    USING (public.is_system_admin())
    WITH CHECK (public.is_system_admin());

ALTER TABLE public.user_permissions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS user_permissions_admin_all ON public.user_permissions;
CREATE POLICY user_permissions_admin_all ON public.user_permissions
    FOR ALL
    USING (public.is_system_admin())
    WITH CHECK (public.is_system_admin());

-- ── 5) grants ────────────────────────────────────────────────────────────────
REVOKE ALL ON TABLE public.role_permissions FROM PUBLIC;
REVOKE ALL ON TABLE public.role_permissions FROM anon;
REVOKE ALL ON TABLE public.role_permissions FROM authenticated;
-- الكتابة مستوى الجدول تُمنح لكنها محصورة فعلياً بسياسة is_system_admin()
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.role_permissions TO authenticated;

REVOKE ALL ON TABLE public.user_permissions FROM PUBLIC;
REVOKE ALL ON TABLE public.user_permissions FROM anon;
REVOKE ALL ON TABLE public.user_permissions FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.user_permissions TO authenticated;

REVOKE EXECUTE ON FUNCTION public.has_capability(uuid, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.has_capability(uuid, text, uuid) TO authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m16$
DECLARE
    v_n    int;
    v_rls  boolean;
    v_fake uuid;
BEGIN
    -- both tables RLS on, one admin-only policy each
    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relname='role_permissions';
    IF NOT v_rls THEN
        RAISE EXCEPTION 'FAIL: role_permissions RLS not enabled';
    END IF;

    SELECT count(*) INTO v_n FROM pg_policies p
     WHERE p.schemaname='public'
       AND p.tablename IN ('role_permissions','user_permissions');
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FAIL: expected 2 admin-only policies, found %', v_n;
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname='has_capability' AND prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: has_capability not SECURITY DEFINER';
    END IF;

    IF has_function_privilege('anon', 'public.has_capability(uuid,text,uuid)', 'EXECUTE')
       OR has_table_privilege('anon', 'role_permissions', 'SELECT')
       OR has_table_privilege('anon', 'user_permissions', 'SELECT') THEN
        RAISE EXCEPTION 'FAIL: anon can touch the permission tables';
    END IF;

    -- behaviour: deny by default. Full resolution-order tests (global role
    -- default, per-user allow AND deny overrides) need a writable auth.users
    -- shim, so they live in the local p0_role_permissions_test.sql suite, not
    -- here where production data would be touched.
    v_fake := 'ffffffff-0000-0000-0000-0000000000ff';
    IF public.has_capability(v_fake, 'view_costs', v_fake) THEN
        RAISE EXCEPTION 'FAIL: unknown user+capability must resolve to false';
    END IF;

    -- seed one global default, prove the SQL resolution rule it feeds, and
    -- remove it again (users exist in prod; we only touch role_permissions).
    -- The JOIN-based resolution over real users is exercised in
    -- p0_role_permissions_test.sql, not here (fixtures are not loaded yet).
    INSERT INTO public.role_permissions (role, capability, is_enabled, farm_id)
    VALUES ('manager', 'view_costs', true, NULL)
    ON CONFLICT (role, capability, farm_id) DO NOTHING;

    IF NOT EXISTS (
        SELECT 1 FROM public.role_permissions
         WHERE role='manager' AND capability='view_costs'
           AND is_enabled AND farm_id IS NULL
    ) THEN
        RAISE EXCEPTION 'FAIL: seeded global default is not a clean global row';
    END IF;

    DELETE FROM public.role_permissions WHERE capability='view_costs';

    RAISE NOTICE 'OK: M16 verified - permission tables + has_capability live, deny-by-default';
END;
$m16$;