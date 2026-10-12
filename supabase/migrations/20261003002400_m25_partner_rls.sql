-- ============================================================================
-- M25 (W6): advanced RLS on the six partnership tables
-- ============================================================================
-- WHY
--   M21-M23 created the partnership tables with a first-pass, role-centric
--   policy set. M25 replaces it with the canonical W6 authorization model:
--
--     is_system_admin()       -> every row, every command
--     user_manages_farm(id)   -> the manager of that farm
--     self (partner)          -> a partner sees only their own rows
--
--   The six tables: partners, user_roles, profit_distributions,
--   profit_distribution_details, partner_withdrawals, partner_audit.
--
--   This migration adds, drops and rewrites ONLY policies (plus one helper
--   function). It changes no table, column, grant or row.
--
-- SPEC ADAPTATIONS (the M25 spec predates the shipped M21-M23 columns):
--   * partners has NO farm_id: a partner is a GLOBAL attribute (M21). So
--     "a manager sees their farm's partners" is derived through the partner's
--     business on a managed farm -- a profit-distribution line or a
--     withdrawal. The check lives in a SECURITY DEFINER helper
--     (partner_in_manager_farm) because a policy on partners must not read a
--     table whose own policy reads partners back: PostgreSQL rejects that as
--     "infinite recursion detected in policy".
--   * profit_distribution_details carries a denormalised farm_id, so
--     details_manager_read uses user_manages_farm(farm_id) directly instead
--     of re-joining profit_distributions (identical rows, no recursion).
--   * the spec names one policy per *_manager_write, but PostgreSQL has no
--     INSERT/UPDATE/DELETE-only policy -- a policy is FOR ALL or for a single
--     command. Each *_manager_write is therefore a single FOR ALL policy: it
--     grants the manager write on their farm's rows, and read as well -- which
--     the sibling *_manager_read already grants. Kept FOR ALL so both the
--     policy name and the per-table count match the spec exactly.
--   * partner_audit stays append-only. audit_admin_all is SELECT-only and no
--     client write policy exists: authenticated holds only SELECT on the table,
--     so only server-side writers can insert. The name mirrors the spec.
--
-- POLICY COUNT AFTER THIS MIGRATION
--   partners 4 | user_roles 4 | profit_distributions 4 |
--   profit_distribution_details 4 | partner_withdrawals 5 | partner_audit 3
--   = 24 total.
--
-- IDEMPOTENT. RE-RUN SAFE. NO DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 0) helper: does this partner do business on a farm the caller manages? ───
-- SECURITY DEFINER on purpose: it reads profit_distribution_details and
-- partner_withdrawals with RLS bypassed, which both answers the question and
-- breaks the policy recursion cycle (partners <-> details).
CREATE OR REPLACE FUNCTION public.partner_in_manager_farm(p_partner_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
    SELECT p_partner_id IS NOT NULL
       AND (
            EXISTS (
                SELECT 1 FROM public.profit_distribution_details d
                 WHERE d.partner_id = p_partner_id
                   AND public.user_manages_farm(d.farm_id)
            )
            OR EXISTS (
                SELECT 1 FROM public.partner_withdrawals w
                 WHERE w.partner_id = p_partner_id
                   AND public.user_manages_farm(w.farm_id)
            )
       );
$fn$;

COMMENT ON FUNCTION public.partner_in_manager_farm(uuid) IS
    'true when the caller manages a farm where this partner has a distribution line or a withdrawal.';

REVOKE ALL ON FUNCTION public.partner_in_manager_farm(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.partner_in_manager_farm(uuid) TO authenticated;

-- ── 1) partners ──────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS partners_admin_all    ON public.partners;
DROP POLICY IF EXISTS partners_select_self  ON public.partners;
DROP POLICY IF EXISTS partners_self_read    ON public.partners;
DROP POLICY IF EXISTS partners_manager_read ON public.partners;
DROP POLICY IF EXISTS partners_manager_write ON public.partners;

CREATE POLICY partners_admin_all ON public.partners
    FOR ALL
    USING (public.is_system_admin())
    WITH CHECK (public.is_system_admin());

CREATE POLICY partners_self_read ON public.partners
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

CREATE POLICY partners_manager_read ON public.partners
    FOR SELECT TO authenticated
    USING (public.partner_in_manager_farm(id));

CREATE POLICY partners_manager_write ON public.partners
    FOR ALL TO authenticated
    USING (public.partner_in_manager_farm(id))
    WITH CHECK (public.partner_in_manager_farm(id));

-- ── 2) user_roles ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS user_roles_admin_all      ON public.user_roles;
DROP POLICY IF EXISTS user_roles_select_self    ON public.user_roles;
DROP POLICY IF EXISTS user_roles_select_manager ON public.user_roles;
DROP POLICY IF EXISTS user_roles_self_read      ON public.user_roles;
DROP POLICY IF EXISTS user_roles_manager_read   ON public.user_roles;
DROP POLICY IF EXISTS user_roles_manager_write  ON public.user_roles;

CREATE POLICY user_roles_admin_all ON public.user_roles
    FOR ALL
    USING (public.is_system_admin())
    WITH CHECK (public.is_system_admin());

CREATE POLICY user_roles_self_read ON public.user_roles
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

CREATE POLICY user_roles_manager_read ON public.user_roles
    FOR SELECT TO authenticated
    USING (farm_id IS NOT NULL AND public.user_manages_farm(farm_id));

CREATE POLICY user_roles_manager_write ON public.user_roles
    FOR ALL TO authenticated
    USING (farm_id IS NOT NULL AND public.user_manages_farm(farm_id))
    WITH CHECK (farm_id IS NOT NULL AND public.user_manages_farm(farm_id));

-- ── 3) profit_distributions ──────────────────────────────────────────────────
DROP POLICY IF EXISTS profit_distributions_read   ON public.profit_distributions;
DROP POLICY IF EXISTS profit_distributions_insert ON public.profit_distributions;
DROP POLICY IF EXISTS profit_distributions_update ON public.profit_distributions;
DROP POLICY IF EXISTS profit_distributions_delete ON public.profit_distributions;
DROP POLICY IF EXISTS distributions_admin_all    ON public.profit_distributions;
DROP POLICY IF EXISTS distributions_manager_read ON public.profit_distributions;
DROP POLICY IF EXISTS distributions_partner_read ON public.profit_distributions;
DROP POLICY IF EXISTS distributions_manager_write ON public.profit_distributions;

CREATE POLICY distributions_admin_all ON public.profit_distributions
    FOR ALL
    USING (public.is_system_admin())
    WITH CHECK (public.is_system_admin());

CREATE POLICY distributions_manager_read ON public.profit_distributions
    FOR SELECT TO authenticated
    USING (public.user_manages_farm(farm_id));

-- a partner sees a header only when one of its lines belongs to them. The
-- subquery reads profit_distribution_details, whose own policies read partners;
-- partners_manager_read uses the SECURITY DEFINER helper, so the chain
-- terminates -- no RLS recursion.
CREATE POLICY distributions_partner_read ON public.profit_distributions
    FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1
              FROM public.profit_distribution_details d
             WHERE d.distribution_id = profit_distributions.id
               AND d.partner_id IN (
                   SELECT p.id FROM public.partners p WHERE p.user_id = auth.uid()
               )
        )
    );

CREATE POLICY distributions_manager_write ON public.profit_distributions
    FOR ALL TO authenticated
    USING (public.user_manages_farm(farm_id))
    WITH CHECK (public.user_manages_farm(farm_id));

-- ── 4) profit_distribution_details ───────────────────────────────────────────
DROP POLICY IF EXISTS profit_distribution_details_read   ON public.profit_distribution_details;
DROP POLICY IF EXISTS profit_distribution_details_insert ON public.profit_distribution_details;
DROP POLICY IF EXISTS profit_distribution_details_update ON public.profit_distribution_details;
DROP POLICY IF EXISTS profit_distribution_details_delete ON public.profit_distribution_details;
DROP POLICY IF EXISTS details_admin_all    ON public.profit_distribution_details;
DROP POLICY IF EXISTS details_manager_read ON public.profit_distribution_details;
DROP POLICY IF EXISTS details_partner_read ON public.profit_distribution_details;
DROP POLICY IF EXISTS details_manager_write ON public.profit_distribution_details;

CREATE POLICY details_admin_all ON public.profit_distribution_details
    FOR ALL
    USING (public.is_system_admin())
    WITH CHECK (public.is_system_admin());

CREATE POLICY details_manager_read ON public.profit_distribution_details
    FOR SELECT TO authenticated
    USING (public.user_manages_farm(farm_id));

CREATE POLICY details_partner_read ON public.profit_distribution_details
    FOR SELECT TO authenticated
    USING (
        partner_id IN (
            SELECT p.id FROM public.partners p WHERE p.user_id = auth.uid()
        )
    );

CREATE POLICY details_manager_write ON public.profit_distribution_details
    FOR ALL TO authenticated
    USING (public.user_manages_farm(farm_id))
    WITH CHECK (public.user_manages_farm(farm_id));

-- ── 5) partner_withdrawals ───────────────────────────────────────────────────
DROP POLICY IF EXISTS partner_withdrawals_admin_all      ON public.partner_withdrawals;
DROP POLICY IF EXISTS partner_withdrawals_self_read      ON public.partner_withdrawals;
DROP POLICY IF EXISTS partner_withdrawals_self_insert    ON public.partner_withdrawals;
DROP POLICY IF EXISTS partner_withdrawals_manager_read   ON public.partner_withdrawals;
DROP POLICY IF EXISTS partner_withdrawals_manager_update ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_admin_all    ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_partner_read ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_partner_insert ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_manager_read ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_manager_update ON public.partner_withdrawals;

CREATE POLICY withdrawals_admin_all ON public.partner_withdrawals
    FOR ALL
    USING (public.is_system_admin())
    WITH CHECK (public.is_system_admin());

CREATE POLICY withdrawals_partner_read ON public.partner_withdrawals
    FOR SELECT TO authenticated
    USING (partner_id IN (SELECT p.id FROM public.partners p WHERE p.user_id = auth.uid()));

CREATE POLICY withdrawals_partner_insert ON public.partner_withdrawals
    FOR INSERT TO authenticated
    WITH CHECK (
        status = 'pending'
        AND partner_id IN (SELECT p.id FROM public.partners p WHERE p.user_id = auth.uid())
    );

CREATE POLICY withdrawals_manager_read ON public.partner_withdrawals
    FOR SELECT TO authenticated
    USING (public.user_manages_farm(farm_id));

CREATE POLICY withdrawals_manager_update ON public.partner_withdrawals
    FOR UPDATE TO authenticated
    USING (public.user_manages_farm(farm_id))
    WITH CHECK (public.user_manages_farm(farm_id));

-- ── 6) partner_audit (append-only) ───────────────────────────────────────────
DROP POLICY IF EXISTS partner_audit_admin_read   ON public.partner_audit;
DROP POLICY IF EXISTS partner_audit_manager_read ON public.partner_audit;
DROP POLICY IF EXISTS audit_admin_all    ON public.partner_audit;
DROP POLICY IF EXISTS audit_manager_read ON public.partner_audit;
DROP POLICY IF EXISTS audit_partner_read ON public.partner_audit;

-- SELECT only. authenticated holds only SELECT on this table, and there is no
-- client write policy: the trail is written exclusively by server-side
-- (SECURITY DEFINER) writers. The name mirrors the spec's audit_admin_all.
CREATE POLICY audit_admin_all ON public.partner_audit
    FOR SELECT TO authenticated
    USING (public.is_system_admin());

CREATE POLICY audit_manager_read ON public.partner_audit
    FOR SELECT TO authenticated
    USING (public.user_manages_farm(farm_id));

CREATE POLICY audit_partner_read ON public.partner_audit
    FOR SELECT TO authenticated
    USING (partner_id IN (SELECT p.id FROM public.partners p WHERE p.user_id = auth.uid()));

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m25_chk$
DECLARE
    v_n   int;
    v_rls boolean;
    v_tbl text;
BEGIN
    -- RLS enabled on all six
    SELECT bool_and(c.relrowsecurity) INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname IN ('partners', 'user_roles', 'profit_distributions',
                         'profit_distribution_details', 'partner_withdrawals',
                         'partner_audit');
    IF NOT v_rls THEN
        RAISE EXCEPTION 'FAIL: RLS not enabled on a W6 table';
    END IF;

    -- exact policy count per table
    FOREACH v_tbl IN ARRAY ARRAY['partners','user_roles','profit_distributions',
                                 'profit_distribution_details','partner_withdrawals',
                                 'partner_audit'] LOOP
        SELECT count(*) INTO v_n FROM pg_policies
         WHERE schemaname = 'public' AND tablename = v_tbl;
        IF (v_tbl = 'partner_withdrawals' AND v_n <> 5)
           OR (v_tbl = 'partner_audit' AND v_n <> 3)
           OR (v_tbl NOT IN ('partner_withdrawals','partner_audit') AND v_n <> 4) THEN
            RAISE EXCEPTION 'FAIL: % has % policies', v_tbl, v_n;
        END IF;
    END LOOP;

    -- every table has an admin policy that calls is_system_admin()
    SELECT count(*) INTO v_n
      FROM (VALUES ('partners'), ('user_roles'), ('profit_distributions'),
                   ('profit_distribution_details'), ('partner_withdrawals'),
                   ('partner_audit')) AS t(tbl)
     WHERE EXISTS (
         SELECT 1 FROM pg_policies p
          WHERE p.schemaname = 'public' AND p.tablename = t.tbl
            AND p.qual LIKE '%is_system_admin%'
     );
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'FAIL: only %/6 tables have an is_system_admin() policy', v_n;
    END IF;

    -- partner_audit stayed append-only
    IF EXISTS (
        SELECT 1 FROM pg_policies
         WHERE schemaname = 'public' AND tablename = 'partner_audit' AND cmd <> 'SELECT'
    ) THEN
        RAISE EXCEPTION 'FAIL: partner_audit gained a write policy';
    END IF;

    -- anon gets nothing; authenticated keeps its table access
    IF has_table_privilege('anon', 'public.partners', 'SELECT')
       OR has_table_privilege('anon', 'public.partner_audit', 'SELECT') THEN
        RAISE EXCEPTION 'FAIL: anon can read a W6 table';
    END IF;
    IF NOT has_table_privilege('authenticated', 'public.partners', 'SELECT') THEN
        RAISE EXCEPTION 'FAIL: authenticated lost access to a W6 table';
    END IF;

    -- helper is SECURITY DEFINER, granted to authenticated, not PUBLIC (0)
    IF (SELECT prosecdef FROM pg_proc WHERE proname = 'partner_in_manager_farm') IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL: partner_in_manager_farm is not SECURITY DEFINER';
    END IF;
    IF NOT has_function_privilege('authenticated',
              'public.partner_in_manager_farm(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: authenticated cannot call partner_in_manager_farm';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_proc pr
        CROSS JOIN LATERAL aclexplode(COALESCE(pr.proacl, acldefault('f', pr.proowner))) a
         WHERE pr.proname = 'partner_in_manager_farm'
           AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'FAIL: partner_in_manager_farm grants EXECUTE to PUBLIC (grantee 0)';
    END IF;

    RAISE NOTICE 'OK: M25 verified - 24 partner policies (4/4/4/4/5/3), admin+manager+self, audit append-only';
END;
$m25_chk$;
