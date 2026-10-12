-- ============================================================================
-- M21 (W6): partners + user_roles — the partner attribute and dynamic roles
-- ============================================================================
-- WHY
--   W6 introduces partnership accounting. Two primitives come first:
--
--     partners   -- a PARTNER is an attribute of a person, not a role. A
--                   partner may be worker, manager, system_admin, or none of
--                   them (a pure investor with no login). The profit share is
--                   dynamic: percentage, shares, salary, or mixed, and it is
--                   configured per partner and (later) per farm/cycle.
--
--     user_roles -- the DYNAMIC roles a user actually holds, per farm
--                   (farm_id NULL = global). This is deliberately separate
--                   from users.role (the single base role kept for backward
--                   compatibility) and from role_permissions (role default
--                   capabilities, M16). The effective permission of a user is:
--
--                       role        (users.role, legacy base role)
--                     + user_roles  (this table, dynamic, per farm)
--                     + partner     (partners attribute + share model)
--                     + custom      (user_permissions overrides, M16)
--
--   M21 ships ONLY these two tables (DDL + RLS + triggers + indexes). The
--   profit engine (profit_distributions, withdrawals, the six functions) and
--   the permission resolution that consumes user_roles arrive in M22-M25.
--
-- DESIGN
--   * partners.user_id is optional (a partner need not have an account) and
--     ON DELETE SET NULL: deleting a login must not delete the partner record.
--   * user_roles.user_id is NOT NULL ON DELETE RESTRICT (same as
--     user_permissions.user_id): a user that still holds roles cannot be
--     erased out from under the ledger.
--   * farm_id is NULL = global role; farm-scoped rows use ON DELETE RESTRICT.
--   * NULLS NOT DISTINCT on (user_id, role, farm_id): a global role cannot be
--     inserted twice (PG15 feature, matching M16's role_permissions_unique).
--
-- SECURITY NOTES
--   * both tables are RLS: system_admin has full access; a partner may SELECT
--     their own partners row; a user may SELECT their own user_roles; a manager
--     may SELECT the farm-scoped roles of the farms they manage. All WRITES
--     are admin-only (WITH CHECK is_system_admin()).
--   * grants follow M16: table DML to authenticated, RLS decides rows; anon
--     and PUBLIC get nothing.
--   * the PUBLIC-exposure assertion uses aclexplode(grantee = 0), not
--     has_function_privilege('PUBLIC', ...).
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) partners ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.partners (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        uuid REFERENCES public.users(id) ON DELETE SET NULL,
    name           text NOT NULL CHECK (char_length(btrim(name)) > 0),
    phone          text,
    national_id    text,
    status         text NOT NULL DEFAULT 'active'
                       CHECK (status IN ('active', 'inactive', 'suspended')),
    partner_role   text NOT NULL DEFAULT 'investor'
                       CHECK (partner_role IN ('investor', 'worker', 'manager', 'silent', 'mixed')),
    share_model    text NOT NULL DEFAULT 'percentage'
                       CHECK (share_model IN ('percentage', 'shares', 'salary', 'mixed')),
    percentage     numeric(9,4)
                       CHECK (percentage IS NULL OR (percentage >= 0 AND percentage <= 100)),
    shares         numeric(18,4)
                       CHECK (shares IS NULL OR shares >= 0),
    salary_amount  numeric(16,8)
                       CHECK (salary_amount IS NULL OR salary_amount >= 0),
    salary_period  text
                       CHECK (salary_period IS NULL
                              OR salary_period IN ('monthly', 'weekly', 'daily', 'per_cycle')),
    currency       text NOT NULL DEFAULT 'dollar'
                       CHECK (currency IN ('dollar', 'lira')),
    effective_from date NOT NULL DEFAULT CURRENT_DATE,
    effective_to   date,
    meta           jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_by     uuid REFERENCES public.users(id) ON DELETE SET NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz,
    CONSTRAINT partners_user_unique UNIQUE (user_id),
    CONSTRAINT partners_share_model_fields CHECK (
        (share_model = 'percentage' AND percentage IS NOT NULL)
        OR (share_model = 'shares' AND shares IS NOT NULL)
        OR (share_model = 'salary' AND salary_amount IS NOT NULL
                                  AND salary_period IS NOT NULL)
        OR (share_model = 'mixed'  AND salary_amount IS NOT NULL
                                  AND salary_period IS NOT NULL
                                  AND (percentage IS NOT NULL OR shares IS NOT NULL))
    ),
    CONSTRAINT partners_effective_range
        CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX IF NOT EXISTS idx_partners_user
    ON public.partners (user_id);
CREATE INDEX IF NOT EXISTS idx_partners_status
    ON public.partners (status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_partners_role
    ON public.partners (partner_role) WHERE deleted_at IS NULL;

DROP TRIGGER IF EXISTS trg_partners_updated_at ON public.partners;
CREATE TRIGGER trg_partners_updated_at
    BEFORE UPDATE ON public.partners
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMENT ON TABLE public.partners IS
    'W6: a partner is an attribute of a person, not a role. Share model is dynamic.';
COMMENT ON COLUMN public.partners.share_model IS
    'percentage | shares | salary | mixed -- which of the share columns is authoritative.';

-- ── 2) user_roles ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_roles (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    farm_id        uuid REFERENCES public.farms(id) ON DELETE RESTRICT,
    role           text NOT NULL CHECK (char_length(btrim(role)) > 0),
    is_primary     boolean NOT NULL DEFAULT false,
    effective_from date NOT NULL DEFAULT CURRENT_DATE,
    effective_to   date,
    granted_by     uuid REFERENCES public.users(id) ON DELETE SET NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT user_roles_unique UNIQUE NULLS NOT DISTINCT (user_id, role, farm_id),
    CONSTRAINT user_roles_effective_range
        CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

-- at most one primary role per user per farm (global farm = sentinel uuid)
CREATE UNIQUE INDEX IF NOT EXISTS ux_user_roles_primary
    ON public.user_roles
       (user_id, COALESCE(farm_id, '00000000-0000-0000-0000-000000000000'::uuid))
    WHERE is_primary;

CREATE INDEX IF NOT EXISTS idx_user_roles_user
    ON public.user_roles (user_id);
CREATE INDEX IF NOT EXISTS idx_user_roles_farm
    ON public.user_roles (farm_id);
CREATE INDEX IF NOT EXISTS idx_user_roles_role
    ON public.user_roles (role);

DROP TRIGGER IF EXISTS trg_user_roles_updated_at ON public.user_roles;
CREATE TRIGGER trg_user_roles_updated_at
    BEFORE UPDATE ON public.user_roles
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMENT ON TABLE public.user_roles IS
    'W6: dynamic roles a user holds, per farm (farm_id NULL = global).';

-- ── 3) RLS ───────────────────────────────────────────────────────────────────
ALTER TABLE public.partners ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS partners_admin_all ON public.partners;
CREATE POLICY partners_admin_all ON public.partners
    FOR ALL
    USING (public.is_system_admin())
    WITH CHECK (public.is_system_admin());

DROP POLICY IF EXISTS partners_select_self ON public.partners;
CREATE POLICY partners_select_self ON public.partners
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_roles_admin_all ON public.user_roles;
CREATE POLICY user_roles_admin_all ON public.user_roles
    FOR ALL
    USING (public.is_system_admin())
    WITH CHECK (public.is_system_admin());

DROP POLICY IF EXISTS user_roles_select_self ON public.user_roles;
CREATE POLICY user_roles_select_self ON public.user_roles
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

DROP POLICY IF EXISTS user_roles_select_manager ON public.user_roles;
CREATE POLICY user_roles_select_manager ON public.user_roles
    FOR SELECT TO authenticated
    USING (farm_id IS NOT NULL AND public.user_manages_farm(farm_id));

-- ── 4) grants (table-level DML; RLS decides the rows) ────────────────────────
REVOKE ALL ON TABLE public.partners FROM PUBLIC;
REVOKE ALL ON TABLE public.partners FROM anon;
REVOKE ALL ON TABLE public.partners FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.partners TO authenticated;

REVOKE ALL ON TABLE public.user_roles FROM PUBLIC;
REVOKE ALL ON TABLE public.user_roles FROM anon;
REVOKE ALL ON TABLE public.user_roles FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.user_roles TO authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m21_chk$
DECLARE
    v_n    int;
    v_rls  boolean;
    v_fake uuid := 'ffffffff-0000-0000-0000-0000000000ee';
BEGIN
    -- both tables exist
    IF to_regclass('public.partners') IS NULL OR to_regclass('public.user_roles') IS NULL THEN
        RAISE EXCEPTION 'FAIL: W6 base tables missing';
    END IF;

    -- RLS enabled on both
    SELECT bool_and(c.relrowsecurity) INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('partners', 'user_roles');
    IF NOT v_rls THEN
        RAISE EXCEPTION 'FAIL: RLS not enabled on partners/user_roles';
    END IF;

    -- expected policies present
    SELECT count(*) INTO v_n FROM pg_policies
     WHERE schemaname = 'public'
       AND policyname IN ('partners_admin_all', 'partners_select_self',
                          'user_roles_admin_all', 'user_roles_select_self',
                          'user_roles_select_manager');
    IF v_n <> 5 THEN
        RAISE EXCEPTION 'FAIL: expected 5 W6 policies, found %', v_n;
    END IF;

    -- updated_at triggers attached
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE NOT tgisinternal
       AND tgname IN ('trg_partners_updated_at', 'trg_user_roles_updated_at');
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FAIL: updated_at triggers missing';
    END IF;

    -- uniqueness + FK delete rules
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'user_roles_unique'
           AND conrelid = 'public.user_roles'::regclass
    ) THEN
        RAISE EXCEPTION 'FAIL: user_roles_unique constraint missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'partners_user_id_fkey' AND confdeltype = 'n'
    ) THEN
        RAISE EXCEPTION 'FAIL: partners.user_id FK must be ON DELETE SET NULL';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'user_roles_user_id_fkey' AND confdeltype = 'r'
    ) THEN
        RAISE EXCEPTION 'FAIL: user_roles.user_id FK must be ON DELETE RESTRICT';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'user_roles_farm_id_fkey' AND confdeltype = 'r'
    ) THEN
        RAISE EXCEPTION 'FAIL: user_roles.farm_id FK must be ON DELETE RESTRICT';
    END IF;

    -- anon gets nothing; authenticated gets table DML
    IF has_table_privilege('anon', 'public.partners', 'SELECT')
       OR has_table_privilege('anon', 'public.user_roles', 'SELECT') THEN
        RAISE EXCEPTION 'FAIL: anon can read W6 tables';
    END IF;
    IF NOT has_table_privilege('authenticated', 'public.partners', 'SELECT')
       OR NOT has_table_privilege('authenticated', 'public.user_roles', 'SELECT') THEN
        RAISE EXCEPTION 'FAIL: authenticated lost table access on W6 tables';
    END IF;

    -- no PUBLIC (grantee 0) table privileges on either table
    IF EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
        WHERE n.nspname = 'public'
          AND c.relname IN ('partners', 'user_roles')
          AND a.grantee = 0
    ) THEN
        RAISE EXCEPTION 'FAIL: W6 tables still grant to PUBLIC (grantee 0)';
    END IF;

    -- deny-by-default: an unknown user has no dynamic role
    PERFORM 1 FROM public.user_roles WHERE user_id = v_fake LIMIT 1;

    RAISE NOTICE 'OK: M21 verified - partners + user_roles live, RLS + triggers + grants correct';
END;
$m21_chk$;
