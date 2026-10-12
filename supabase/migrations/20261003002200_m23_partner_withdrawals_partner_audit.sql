-- ============================================================================
-- M23 (W6): partner_withdrawals + partner_audit
-- ============================================================================
-- WHY
--   M22 gave us the profit ledger. M23 adds the two tables the money flow and
--   the governance trail still need:
--
--     partner_withdrawals -- a partner's request to take cash out of their
--                            share, moving pending -> approved -> paid (or
--                            rejected/cancelled). It may be tied to a specific
--                            profit distribution, or stand alone.
--     partner_audit       -- an append-only record of who changed what on the
--                            partnership (share changes, permission changes,
--                            withdrawal decisions, distribution events). The
--                            client never writes it: triggers / server
--                            functions do.
--
-- M23 ships the schema (DDL + RLS + triggers + indexes + guard functions).
-- The workflow functions (approve_withdrawal, partner_pending_withdrawal, ...)
-- arrive in M24.
--
-- INTEGRITY
--   * amount NUMERIC(16,8) > 0, currency dollar/lira, status limited to the
--     five states.
--   * status <-> fields: a rejected request must carry a rejection_reason, a
--     paid request must carry a paid_at. A BEFORE trigger stamps reviewed_at /
--     paid_at when the transition happens, so the CHECKs cannot be dodged.
--   * validate_partner_withdrawal: the partner must exist, and a withdrawal
--     tied to a distribution must point at a distribution of the SAME farm.
--   * guard_withdrawal_status: only pending->{approved,rejected,cancelled} and
--     approved->{paid,cancelled} are legal; anything else raises.
--
-- SCOPING / RLS
--   * admin: is_system_admin() full access.
--   * partner: sees and CREATES only their own requests, and only as 'pending'
--     (a partner cannot self-approve or self-pay).
--   * manager: reads and updates the withdrawals of the farms they manage.
--   * partner_audit is admin+manager READ only; no INSERT/UPDATE/DELETE policy,
--     so the client cannot forge or erase the trail.
--   * FK delete rules: partner_id / farm_id / requested_by -> RESTRICT;
--     distribution_id / reviewed_by -> SET NULL; no CASCADE.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) partner_withdrawals ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.partner_withdrawals (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id        uuid NOT NULL REFERENCES public.partners(id) ON DELETE RESTRICT,
    farm_id           uuid NOT NULL REFERENCES public.farms(id) ON DELETE RESTRICT,
    distribution_id   uuid REFERENCES public.profit_distributions(id) ON DELETE SET NULL,
    amount            numeric(16,8) NOT NULL CHECK (amount > 0),
    currency          text NOT NULL DEFAULT 'dollar'
                          CHECK (currency IN ('dollar', 'lira')),
    status            text NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'approved', 'rejected', 'paid', 'cancelled')),
    requested_at      timestamptz NOT NULL DEFAULT now(),
    requested_by      uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    reason            text,
    reviewed_at       timestamptz,
    reviewed_by       uuid REFERENCES public.users(id) ON DELETE SET NULL,
    rejection_reason  text,
    paid_at           timestamptz,
    payment_method    text,
    notes             text,
    version           bigint NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at        timestamptz,
    CONSTRAINT partner_withdrawals_rejected_reason
        CHECK (status <> 'rejected' OR rejection_reason IS NOT NULL),
    CONSTRAINT partner_withdrawals_paid_at
        CHECK (status <> 'paid' OR paid_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_partner_withdrawals_partner
    ON public.partner_withdrawals (partner_id);
CREATE INDEX IF NOT EXISTS idx_partner_withdrawals_farm
    ON public.partner_withdrawals (farm_id);
CREATE INDEX IF NOT EXISTS idx_partner_withdrawals_status
    ON public.partner_withdrawals (status);
CREATE INDEX IF NOT EXISTS idx_partner_withdrawals_distribution
    ON public.partner_withdrawals (distribution_id);
CREATE INDEX IF NOT EXISTS idx_partner_withdrawals_created
    ON public.partner_withdrawals (created_at DESC);

COMMENT ON TABLE public.partner_withdrawals IS
    'W6: a partner cash-out request. Server guards enforce the status ladder and the tied distribution farm.';

-- ── 2) partner_audit ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.partner_audit (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id        uuid NOT NULL REFERENCES public.farms(id) ON DELETE RESTRICT,
    partner_id     uuid REFERENCES public.partners(id) ON DELETE SET NULL,
    action         text NOT NULL CHECK (action IN (
                       'added', 'removed', 'share_changed', 'permissions_changed',
                       'withdrawal_requested', 'withdrawal_approved', 'withdrawal_rejected',
                       'withdrawal_paid', 'distribution_created', 'distribution_approved')),
    old_values     jsonb,
    new_values     jsonb,
    changed_by     uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    changed_at     timestamptz NOT NULL DEFAULT now(),
    notes          text,
    correlation_id text,
    ip_address     text
);

CREATE INDEX IF NOT EXISTS idx_partner_audit_farm
    ON public.partner_audit (farm_id);
CREATE INDEX IF NOT EXISTS idx_partner_audit_partner
    ON public.partner_audit (partner_id);
CREATE INDEX IF NOT EXISTS idx_partner_audit_action
    ON public.partner_audit (action);
CREATE INDEX IF NOT EXISTS idx_partner_audit_changed_at
    ON public.partner_audit (changed_at DESC);

COMMENT ON TABLE public.partner_audit IS
    'W6: append-only partnership trail. No client INSERT/UPDATE/DELETE policy -- only server-side writers.';

-- ── 3) guard functions ───────────────────────────────────────────────────────
-- 3a) partner + farm consistency
CREATE OR REPLACE FUNCTION public.validate_partner_withdrawal()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m23val$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.partners WHERE id = NEW.partner_id) THEN
        RAISE EXCEPTION 'PARTNER_NOT_FOUND: الشريك غير موجود (%)', NEW.partner_id;
    END IF;

    IF NEW.distribution_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.profit_distributions d
             WHERE d.id = NEW.distribution_id
               AND d.farm_id = NEW.farm_id
        ) THEN
            RAISE EXCEPTION
                'WITHDRAWAL_DISTRIBUTION_MISMATCH: التوزيع لا يخص نفس المزرعة';
        END IF;
    END IF;

    RETURN NEW;
END;
$m23val$;

-- 3b) the status ladder
CREATE OR REPLACE FUNCTION public.guard_withdrawal_status()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m23grd$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT (
               (OLD.status = 'pending'  AND NEW.status IN ('approved', 'rejected', 'cancelled'))
            OR (OLD.status = 'approved' AND NEW.status IN ('paid', 'cancelled'))
        ) THEN
            RAISE EXCEPTION 'INVALID_STATUS_TRANSITION: % -> %', OLD.status, NEW.status;
        END IF;
    END IF;

    IF NEW.status IN ('approved', 'rejected') AND NEW.reviewed_at IS NULL THEN
        NEW.reviewed_at := now();
    END IF;
    IF NEW.status = 'paid' AND NEW.paid_at IS NULL THEN
        NEW.paid_at := now();
    END IF;

    RETURN NEW;
END;
$m23grd$;

-- 3c) the only writer of the audit trail. RLS has no INSERT policy, so the
--     client (and any future caller) must come through here. SECURITY DEFINER
--     lets it write; the is_system_admin() gate stops anyone else.
CREATE OR REPLACE FUNCTION public.record_partner_audit(
    p_farm_id        uuid,
    p_action         text,
    p_changed_by     uuid,
    p_partner_id     uuid    DEFAULT NULL,
    p_old_values     jsonb   DEFAULT NULL,
    p_new_values     jsonb   DEFAULT NULL,
    p_notes          text    DEFAULT NULL,
    p_correlation_id text    DEFAULT NULL,
    p_ip_address     text    DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m23aud$
DECLARE
    v_id uuid;
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: only system_admin may write the partner audit trail';
    END IF;

    INSERT INTO public.partner_audit
        (farm_id, partner_id, action, old_values, new_values,
         changed_by, notes, correlation_id, ip_address)
    VALUES
        (p_farm_id, p_partner_id, p_action, p_old_values, p_new_values,
         p_changed_by, p_notes, p_correlation_id, p_ip_address)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$m23aud$;

-- ── 4) triggers ──────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_partner_withdrawals_updated_at ON public.partner_withdrawals;
CREATE TRIGGER trg_partner_withdrawals_updated_at
    BEFORE UPDATE ON public.partner_withdrawals
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_partner_withdrawals_validate ON public.partner_withdrawals;
CREATE TRIGGER trg_partner_withdrawals_validate
    BEFORE INSERT OR UPDATE ON public.partner_withdrawals
    FOR EACH ROW EXECUTE FUNCTION public.validate_partner_withdrawal();

DROP TRIGGER IF EXISTS trg_partner_withdrawals_guard ON public.partner_withdrawals;
CREATE TRIGGER trg_partner_withdrawals_guard
    BEFORE UPDATE ON public.partner_withdrawals
    FOR EACH ROW EXECUTE FUNCTION public.guard_withdrawal_status();

DROP TRIGGER IF EXISTS trg_partner_withdrawals_sync ON public.partner_withdrawals;
CREATE TRIGGER trg_partner_withdrawals_sync
    AFTER INSERT OR UPDATE ON public.partner_withdrawals
    FOR EACH ROW EXECUTE FUNCTION public.populate_sync_changes();

DROP TRIGGER IF EXISTS trg_partner_withdrawals_tombstone ON public.partner_withdrawals;
CREATE TRIGGER trg_partner_withdrawals_tombstone
    AFTER DELETE ON public.partner_withdrawals
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

-- partner_audit has NO triggers: it is an append-only governance ledger written
-- by server-side writers (record_partner_audit and, from M24, the workflow
-- functions). It is not synced and has no tombstones.

-- ── 5) RLS ───────────────────────────────────────────────────────────────────
ALTER TABLE public.partner_withdrawals ENABLE ROW LEVEL SECURITY;

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

ALTER TABLE public.partner_audit ENABLE ROW LEVEL SECURITY;

-- append-only: the admin policy is READ only. There is deliberately no INSERT/
-- UPDATE/DELETE policy -- server-side writers (SECURITY DEFINER) are the only
-- path that can write the trail.
DROP POLICY IF EXISTS partner_audit_admin_read ON public.partner_audit;
CREATE POLICY partner_audit_admin_read ON public.partner_audit
    FOR SELECT TO authenticated
    USING (public.is_system_admin());

DROP POLICY IF EXISTS partner_audit_manager_read ON public.partner_audit;
CREATE POLICY partner_audit_manager_read ON public.partner_audit
    FOR SELECT TO authenticated
    USING (public.user_manages_farm(farm_id));

-- ── 6) grants ────────────────────────────────────────────────────────────────
-- withdrawals: full DML surface, rows decided by RLS.
REVOKE ALL ON TABLE public.partner_withdrawals FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.partner_withdrawals TO authenticated;

-- audit: READ only. Writes come from server-side writers; the client cannot
-- INSERT/UPDATE/DELETE even if a policy were ever added by mistake.
REVOKE ALL ON TABLE public.partner_audit FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.partner_audit TO authenticated;

-- the audit writer: callable by signed-in users, but only system_admin passes
-- its internal gate. anon/PUBLIC get nothing.
REVOKE ALL ON FUNCTION public.record_partner_audit(uuid, text, uuid, uuid, jsonb, jsonb, text, text, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_partner_audit(uuid, text, uuid, uuid, jsonb, jsonb, text, text, text)
    TO authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m23chk$
DECLARE
    v_n    int;
    v_rls  boolean;
BEGIN
    IF to_regclass('public.partner_withdrawals') IS NULL
       OR to_regclass('public.partner_audit') IS NULL THEN
        RAISE EXCEPTION 'FAIL: W6 withdrawal/audit tables missing';
    END IF;

    SELECT bool_and(c.relrowsecurity) INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname IN ('partner_withdrawals', 'partner_audit');
    IF NOT v_rls THEN
        RAISE EXCEPTION 'FAIL: RLS not enabled on W6 withdrawal/audit tables';
    END IF;

    -- 5 withdrawal policies + 2 audit policies
    SELECT count(*) INTO v_n FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'partner_withdrawals';
    IF v_n <> 5 THEN
        RAISE EXCEPTION 'FAIL: expected 5 withdrawal policies, found %', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'partner_audit';
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FAIL: expected 2 audit policies, found %', v_n;
    END IF;

    -- audit must have NO write policy: only SELECT policies are allowed there
    IF EXISTS (SELECT 1 FROM pg_policies
                WHERE schemaname = 'public' AND tablename = 'partner_audit'
                  AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'FAIL: partner_audit has a write policy (must be read-only)';
    END IF;

    -- state <-> field CHECKs present
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'partner_withdrawals_rejected_reason'
                      AND conrelid = 'public.partner_withdrawals'::regclass) THEN
        RAISE EXCEPTION 'FAIL: rejection_reason CHECK missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'partner_withdrawals_paid_at'
                      AND conrelid = 'public.partner_withdrawals'::regclass) THEN
        RAISE EXCEPTION 'FAIL: paid_at CHECK missing';
    END IF;

    -- triggers attached
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE NOT tgisinternal
       AND tgname IN ('trg_partner_withdrawals_updated_at',
                      'trg_partner_withdrawals_validate',
                      'trg_partner_withdrawals_guard',
                      'trg_partner_withdrawals_sync',
                      'trg_partner_withdrawals_tombstone');
    IF v_n <> 5 THEN
        RAISE EXCEPTION 'FAIL: expected 5 W6 withdrawal triggers, found %', v_n;
    END IF;

    -- partner_audit must have NO user triggers (append-only, server-written)
    IF EXISTS (SELECT 1 FROM pg_trigger
                WHERE NOT tgisinternal
                  AND tgrelid = 'public.partner_audit'::regclass) THEN
        RAISE EXCEPTION 'FAIL: partner_audit has a trigger (must be written only via record_partner_audit)';
    END IF;

    -- guard functions are SECURITY DEFINER
    IF (SELECT count(*) FROM pg_proc
         WHERE proname IN ('validate_partner_withdrawal', 'guard_withdrawal_status')
           AND prosecdef) <> 2 THEN
        RAISE EXCEPTION 'FAIL: W6 guard functions not SECURITY DEFINER';
    END IF;

    -- the audit writer exists, is SECURITY DEFINER, and anon cannot call it
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'public'
                      AND p.proname = 'record_partner_audit'
                      AND p.prosecdef) THEN
        RAISE EXCEPTION 'FAIL: record_partner_audit() missing or not SECURITY DEFINER';
    END IF;
    IF has_function_privilege('anon',
         'public.record_partner_audit(uuid,text,uuid,uuid,jsonb,jsonb,text,text,text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: anon can call record_partner_audit()';
    END IF;

    -- FK delete rules (no CASCADE, RESTRICT where required)
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'partner_withdrawals_farm_id_fkey' AND confdeltype = 'r') THEN
        RAISE EXCEPTION 'FAIL: withdrawals.farm_id FK must be ON DELETE RESTRICT';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'partner_withdrawals_partner_id_fkey' AND confdeltype = 'r') THEN
        RAISE EXCEPTION 'FAIL: withdrawals.partner_id FK must be ON DELETE RESTRICT';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conrelid IN ('public.partner_withdrawals'::regclass,
                                   'public.partner_audit'::regclass)
                  AND confdeltype = 'c') THEN
        RAISE EXCEPTION 'FAIL: a W6 withdrawal/audit FK uses ON DELETE CASCADE';
    END IF;

    -- anon gets nothing; authenticated gets withdrawals DML but audit READ only
    IF has_table_privilege('anon', 'public.partner_withdrawals', 'SELECT')
       OR has_table_privilege('anon', 'public.partner_audit', 'SELECT') THEN
        RAISE EXCEPTION 'FAIL: anon can read W6 withdrawal/audit tables';
    END IF;
    IF NOT has_table_privilege('authenticated', 'public.partner_withdrawals', 'INSERT')
       OR NOT has_table_privilege('authenticated', 'public.partner_audit', 'SELECT') THEN
        RAISE EXCEPTION 'FAIL: authenticated lost expected W6 table access';
    END IF;
    IF has_table_privilege('authenticated', 'public.partner_audit', 'INSERT')
       OR has_table_privilege('authenticated', 'public.partner_audit', 'UPDATE')
       OR has_table_privilege('authenticated', 'public.partner_audit', 'DELETE') THEN
        RAISE EXCEPTION 'FAIL: authenticated must NOT write partner_audit';
    END IF;

    -- never to PUBLIC (grantee 0)
    IF EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
        WHERE n.nspname = 'public'
          AND c.relname IN ('partner_withdrawals', 'partner_audit')
          AND a.grantee = 0
    ) THEN
        RAISE EXCEPTION 'FAIL: W6 withdrawal/audit tables still grant to PUBLIC (grantee 0)';
    END IF;

    RAISE NOTICE 'OK: M23 verified - partner_withdrawals + partner_audit live, guards + RLS + grants correct';
END;
$m23chk$;
