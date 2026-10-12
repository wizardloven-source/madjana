-- ============================================================================
-- M25 rollback: restore the M21-M23 policy set on the six partnership tables
-- ============================================================================
-- M25 only rewrote policies (and added one helper). Its rollback therefore
-- drops the M25 policies + helper and puts the original M21-M23 policies back.
-- No table, column, grant or row is touched.
--
-- SCOPE GUARD: this only makes sense after M21-M23 exist, so it aborts if any
-- of the six tables is missing rather than silently recreating policies on
-- nothing.
--
-- IDEMPOTENT. RE-RUN SAFE. NO DATA IS MODIFIED.
-- ============================================================================

BEGIN;

DO $m25_guard$
BEGIN
    IF to_regclass('public.partners') IS NULL
       OR to_regclass('public.user_roles') IS NULL
       OR to_regclass('public.profit_distributions') IS NULL
       OR to_regclass('public.profit_distribution_details') IS NULL
       OR to_regclass('public.partner_withdrawals') IS NULL
       OR to_regclass('public.partner_audit') IS NULL THEN
        RAISE EXCEPTION 'ABORT: M25 rollback needs the six W6 tables (run it after M21-M23)';
    END IF;
END;
$m25_guard$;

-- ── drop the M25 policies ────────────────────────────────────────────────────
DROP POLICY IF EXISTS partners_admin_all ON public.partners;
DROP POLICY IF EXISTS partners_self_read ON public.partners;
DROP POLICY IF EXISTS partners_manager_read ON public.partners;
DROP POLICY IF EXISTS partners_manager_write ON public.partners;

DROP POLICY IF EXISTS user_roles_admin_all ON public.user_roles;
DROP POLICY IF EXISTS user_roles_self_read ON public.user_roles;
DROP POLICY IF EXISTS user_roles_manager_read ON public.user_roles;
DROP POLICY IF EXISTS user_roles_manager_write ON public.user_roles;

DROP POLICY IF EXISTS distributions_admin_all ON public.profit_distributions;
DROP POLICY IF EXISTS distributions_manager_read ON public.profit_distributions;
DROP POLICY IF EXISTS distributions_partner_read ON public.profit_distributions;
DROP POLICY IF EXISTS distributions_manager_write ON public.profit_distributions;

DROP POLICY IF EXISTS details_admin_all ON public.profit_distribution_details;
DROP POLICY IF EXISTS details_manager_read ON public.profit_distribution_details;
DROP POLICY IF EXISTS details_partner_read ON public.profit_distribution_details;
DROP POLICY IF EXISTS details_manager_write ON public.profit_distribution_details;

DROP POLICY IF EXISTS withdrawals_admin_all ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_partner_read ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_partner_insert ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_manager_read ON public.partner_withdrawals;
DROP POLICY IF EXISTS withdrawals_manager_update ON public.partner_withdrawals;

DROP POLICY IF EXISTS audit_admin_all ON public.partner_audit;
DROP POLICY IF EXISTS audit_manager_read ON public.partner_audit;
DROP POLICY IF EXISTS audit_partner_read ON public.partner_audit;

DROP FUNCTION IF EXISTS public.partner_in_manager_farm(uuid);

-- ── restore the M21-M23 policies ─────────────────────────────────────────────
-- partners (M21)
DROP POLICY IF EXISTS partners_admin_all ON public.partners;
CREATE POLICY partners_admin_all ON public.partners
    FOR ALL
    USING (public.is_system_admin())
    WITH CHECK (public.is_system_admin());

DROP POLICY IF EXISTS partners_select_self ON public.partners;
CREATE POLICY partners_select_self ON public.partners
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

-- user_roles (M21)
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

-- profit_distributions (M22)
DROP POLICY IF EXISTS profit_distributions_read ON public.profit_distributions;
CREATE POLICY profit_distributions_read ON public.profit_distributions
    FOR SELECT TO authenticated
    USING (public.is_system_admin() OR public.user_manages_farm(farm_id));

DROP POLICY IF EXISTS profit_distributions_insert ON public.profit_distributions;
CREATE POLICY profit_distributions_insert ON public.profit_distributions
    FOR INSERT TO authenticated
    WITH CHECK (public.is_system_admin() OR public.user_manages_farm(farm_id));

DROP POLICY IF EXISTS profit_distributions_update ON public.profit_distributions;
CREATE POLICY profit_distributions_update ON public.profit_distributions
    FOR UPDATE TO authenticated
    USING (public.is_system_admin() OR public.user_manages_farm(farm_id))
    WITH CHECK (public.is_system_admin() OR public.user_manages_farm(farm_id));

DROP POLICY IF EXISTS profit_distributions_delete ON public.profit_distributions;
CREATE POLICY profit_distributions_delete ON public.profit_distributions
    FOR DELETE TO authenticated
    USING (public.is_system_admin() OR public.user_manages_farm(farm_id));

-- profit_distribution_details (M22)
DROP POLICY IF EXISTS profit_distribution_details_read ON public.profit_distribution_details;
CREATE POLICY profit_distribution_details_read ON public.profit_distribution_details
    FOR SELECT TO authenticated
    USING (public.is_system_admin()
           OR public.user_manages_farm(farm_id)
           OR EXISTS (SELECT 1 FROM public.partners p
                       WHERE p.id = partner_id AND p.user_id = auth.uid()));

DROP POLICY IF EXISTS profit_distribution_details_insert ON public.profit_distribution_details;
CREATE POLICY profit_distribution_details_insert ON public.profit_distribution_details
    FOR INSERT TO authenticated
    WITH CHECK (public.is_system_admin() OR public.user_manages_farm(farm_id));

DROP POLICY IF EXISTS profit_distribution_details_update ON public.profit_distribution_details;
CREATE POLICY profit_distribution_details_update ON public.profit_distribution_details
    FOR UPDATE TO authenticated
    USING (public.is_system_admin() OR public.user_manages_farm(farm_id))
    WITH CHECK (public.is_system_admin() OR public.user_manages_farm(farm_id));

DROP POLICY IF EXISTS profit_distribution_details_delete ON public.profit_distribution_details;
CREATE POLICY profit_distribution_details_delete ON public.profit_distribution_details
    FOR DELETE TO authenticated
    USING (public.is_system_admin() OR public.user_manages_farm(farm_id));

-- partner_withdrawals (M23)
DROP POLICY IF EXISTS partner_withdrawals_admin_all ON public.partner_withdrawals;
CREATE POLICY partner_withdrawals_admin_all ON public.partner_withdrawals
    FOR ALL
    USING (public.is_system_admin())
    WITH CHECK (public.is_system_admin());

DROP POLICY IF EXISTS partner_withdrawals_self_read ON public.partner_withdrawals;
CREATE POLICY partner_withdrawals_self_read ON public.partner_withdrawals
    FOR SELECT TO authenticated
    USING (partner_id IN (SELECT p.id FROM public.partners p WHERE p.user_id = auth.uid()));

DROP POLICY IF EXISTS partner_withdrawals_self_insert ON public.partner_withdrawals;
CREATE POLICY partner_withdrawals_self_insert ON public.partner_withdrawals
    FOR INSERT TO authenticated
    WITH CHECK (
        status = 'pending'
        AND partner_id IN (SELECT p.id FROM public.partners p WHERE p.user_id = auth.uid())
    );

DROP POLICY IF EXISTS partner_withdrawals_manager_read ON public.partner_withdrawals;
CREATE POLICY partner_withdrawals_manager_read ON public.partner_withdrawals
    FOR SELECT TO authenticated
    USING (public.user_manages_farm(farm_id));

DROP POLICY IF EXISTS partner_withdrawals_manager_update ON public.partner_withdrawals;
CREATE POLICY partner_withdrawals_manager_update ON public.partner_withdrawals
    FOR UPDATE TO authenticated
    USING (public.user_manages_farm(farm_id))
    WITH CHECK (public.user_manages_farm(farm_id));

-- partner_audit (M23)
DROP POLICY IF EXISTS partner_audit_admin_read ON public.partner_audit;
CREATE POLICY partner_audit_admin_read ON public.partner_audit
    FOR SELECT TO authenticated
    USING (public.is_system_admin());

DROP POLICY IF EXISTS partner_audit_manager_read ON public.partner_audit;
CREATE POLICY partner_audit_manager_read ON public.partner_audit
    FOR SELECT TO authenticated
    USING (public.user_manages_farm(farm_id));

COMMIT;
