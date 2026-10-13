-- ============================================================================
-- M22 (W6): profit_distributions + profit_distribution_details
-- ============================================================================
-- WHY
--   M21 gave us partners (the attribute). M22 gives the ledger that turns a
--   farm's profit for a period into per-partner shares:
--
--     profit_distributions       -- one header per (farm[, flock], period):
--                                   the period's revenue, expenses, net profit,
--                                   reserve, and the distributable profit.
--     profit_distribution_details-- one line per partner: their share model,
--                                   the profit share, salary, deductions and
--                                   net amount for that period.
--
--   These are the tables the M24 functions (partner_net_profit,
--   calculate_profit_distribution, approve_withdrawal, ...) will write.
--   M22 ships ONLY the schema (DDL + RLS + triggers + indexes + integrity
--   CHECKs); no calculation logic and no writes to existing tables.
--
-- INTEGRITY (money must never silently drift)
--   * NUMERIC(16,8) for every money column, matching revenue.amount /
--     expenses.amount; exchange_rate NUMERIC(12,4); percentage NUMERIC(9,4).
--   * header arithmetic is enforced: net_profit = total_revenue - total_expenses
--     and distributable_profit = net_profit - reserve_amount. A header that
--     does not add up cannot be stored, by anyone, including the engine.
--   * detail arithmetic is enforced: net_amount = profit_share + salary_total
--     - deductions.
--   * period_end >= period_start; no negative totals.
--   * a period cannot be distributed twice: UNIQUE (farm_id, flock_id,
--     period_start, period_end) NULLS NOT DISTINCT (NULL flock = whole farm).
--
-- SCOPING / RLS
--   * farm_id is denormalised onto details and a COMPOSITE foreign key
--     (distribution_id, farm_id) -> distributions(id, farm_id) makes it
--     impossible to attach a line to the wrong farm. That lets the manager
--     policy use user_manages_farm(farm_id) directly, with no self-join and
--     therefore no RLS recursion.
--   * headers are admin/manager only: a farm's totals are not a worker's or a
--     single partner's business.
--   * a partner sees ONLY their own lines (partner_select_self via
--     partners.user_id = auth.uid()); workers see nothing.
--   * FK delete rules: farm_id / flock_id / distribution_id / partner_id ->
--     RESTRICT; created_by / approved_by -> SET NULL; no CASCADE.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) profit_distributions (header) ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.profit_distributions (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id              uuid NOT NULL REFERENCES public.farms(id) ON DELETE RESTRICT,
    flock_id             uuid REFERENCES public.flocks(id) ON DELETE RESTRICT,
    period_start         date NOT NULL,
    period_end           date NOT NULL,
    label                text,
    status               text NOT NULL DEFAULT 'draft'
                             CHECK (status IN ('draft', 'calculated', 'approved', 'distributed', 'cancelled')),
    total_revenue        numeric(16,8) NOT NULL DEFAULT 0 CHECK (total_revenue >= 0),
    total_expenses       numeric(16,8) NOT NULL DEFAULT 0 CHECK (total_expenses >= 0),
    net_profit           numeric(16,8) NOT NULL DEFAULT 0,
    reserve_amount       numeric(16,8) NOT NULL DEFAULT 0 CHECK (reserve_amount >= 0),
    distributable_profit numeric(16,8) NOT NULL DEFAULT 0,
    currency             text NOT NULL DEFAULT 'dollar' CHECK (currency IN ('dollar', 'lira')),
    exchange_rate        numeric(12,4),
    notes                text,
    meta                 jsonb NOT NULL DEFAULT '{}'::jsonb,
    calculated_at        timestamptz,
    approved_at          timestamptz,
    approved_by          uuid REFERENCES public.users(id) ON DELETE SET NULL,
    created_by           uuid REFERENCES public.users(id) ON DELETE SET NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT profit_distributions_period
        CHECK (period_end >= period_start),
    CONSTRAINT profit_distributions_math
        CHECK (net_profit = total_revenue - total_expenses),
    CONSTRAINT profit_distributions_distributable
        CHECK (distributable_profit = net_profit - reserve_amount),
    CONSTRAINT profit_distributions_period_unique
        UNIQUE NULLS NOT DISTINCT (farm_id, flock_id, period_start, period_end),
    CONSTRAINT profit_distributions_id_farm_unique UNIQUE (id, farm_id)
);

CREATE INDEX IF NOT EXISTS idx_profit_distributions_farm
    ON public.profit_distributions (farm_id, period_end DESC);
CREATE INDEX IF NOT EXISTS idx_profit_distributions_flock
    ON public.profit_distributions (flock_id);
CREATE INDEX IF NOT EXISTS idx_profit_distributions_status
    ON public.profit_distributions (status);

DROP TRIGGER IF EXISTS trg_profit_distributions_updated_at ON public.profit_distributions;
CREATE TRIGGER trg_profit_distributions_updated_at
    BEFORE UPDATE ON public.profit_distributions
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMENT ON TABLE public.profit_distributions IS
    'W6: one profit period per farm (optionally per flock). Money is NUMERIC(16,8); header arithmetic is enforced by CHECK.';

-- ── 2) profit_distribution_details (per-partner lines) ───────────────────────
CREATE TABLE IF NOT EXISTS public.profit_distribution_details (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    distribution_id  uuid NOT NULL REFERENCES public.profit_distributions(id) ON DELETE RESTRICT,
    farm_id          uuid NOT NULL REFERENCES public.farms(id) ON DELETE RESTRICT,
    partner_id       uuid NOT NULL REFERENCES public.partners(id) ON DELETE RESTRICT,
    share_model      text NOT NULL
                         CHECK (share_model IN ('percentage', 'shares', 'salary', 'mixed')),
    percentage       numeric(9,4)
                         CHECK (percentage IS NULL OR (percentage >= 0 AND percentage <= 100)),
    shares           numeric(18,4)
                         CHECK (shares IS NULL OR shares >= 0),
    salary_amount    numeric(16,8)
                         CHECK (salary_amount IS NULL OR salary_amount >= 0),
    salary_period    text
                         CHECK (salary_period IS NULL
                                OR salary_period IN ('monthly', 'weekly', 'daily', 'per_cycle')),
    profit_share     numeric(16,8) NOT NULL DEFAULT 0 CHECK (profit_share >= 0),
    salary_total     numeric(16,8) NOT NULL DEFAULT 0 CHECK (salary_total >= 0),
    deductions       numeric(16,8) NOT NULL DEFAULT 0 CHECK (deductions >= 0),
    net_amount       numeric(16,8) NOT NULL DEFAULT 0,
    currency         text NOT NULL DEFAULT 'dollar' CHECK (currency IN ('dollar', 'lira')),
    status           text NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending', 'approved', 'withdrawn', 'cancelled')),
    note             text,
    meta             jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT profit_distribution_details_math
        CHECK (net_amount = profit_share + salary_total - deductions),
    CONSTRAINT profit_distribution_details_unique
        UNIQUE (distribution_id, partner_id),
    CONSTRAINT profit_distribution_details_dist_farm_fkey
        FOREIGN KEY (distribution_id, farm_id)
        REFERENCES public.profit_distributions (id, farm_id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_pdd_distribution
    ON public.profit_distribution_details (distribution_id);
CREATE INDEX IF NOT EXISTS idx_pdd_partner
    ON public.profit_distribution_details (partner_id);
CREATE INDEX IF NOT EXISTS idx_pdd_farm
    ON public.profit_distribution_details (farm_id);
CREATE INDEX IF NOT EXISTS idx_pdd_status
    ON public.profit_distribution_details (status);

DROP TRIGGER IF EXISTS trg_pdd_updated_at ON public.profit_distribution_details;
CREATE TRIGGER trg_pdd_updated_at
    BEFORE UPDATE ON public.profit_distribution_details
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMENT ON TABLE public.profit_distribution_details IS
    'W6: one line per partner per profit period. farm_id is bound to the header by a composite FK.';

-- ── 3) RLS ───────────────────────────────────────────────────────────────────
ALTER TABLE public.profit_distributions ENABLE ROW LEVEL SECURITY;

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

ALTER TABLE public.profit_distribution_details ENABLE ROW LEVEL SECURITY;

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

-- ── 4) grants (table-level DML; RLS decides the rows) ────────────────────────
REVOKE ALL ON TABLE public.profit_distributions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.profit_distributions TO authenticated;

REVOKE ALL ON TABLE public.profit_distribution_details FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.profit_distribution_details TO authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m22_chk$
DECLARE
    v_n   int;
    v_rls boolean;
BEGIN
    IF to_regclass('public.profit_distributions') IS NULL
       OR to_regclass('public.profit_distribution_details') IS NULL THEN
        RAISE EXCEPTION 'FAIL: W6 profit tables missing';
    END IF;

    SELECT bool_and(c.relrowsecurity) INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname IN ('profit_distributions', 'profit_distribution_details');
    IF NOT v_rls THEN
        RAISE EXCEPTION 'FAIL: RLS not enabled on W6 profit tables';
    END IF;

    -- 4 header policies + 4 detail policies (read folds in partner-self).
    -- Count only the names this migration owns, so a later migration that
    -- replaces or adds policies on the same table cannot break the check.
    SELECT count(*) INTO v_n FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'profit_distributions'
       AND policyname = ANY (ARRAY['profit_distributions_read',
                                   'profit_distributions_insert',
                                   'profit_distributions_update',
                                   'profit_distributions_delete']);
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FAIL: expected 4 header policies, found %', v_n;
    END IF;

    SELECT count(*) INTO v_n FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'profit_distribution_details'
       AND policyname = ANY (ARRAY['profit_distribution_details_read',
                                   'profit_distribution_details_insert',
                                   'profit_distribution_details_update',
                                   'profit_distribution_details_delete']);
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FAIL: expected 4 detail policies, found %', v_n;
    END IF;

    -- the detail read policy must still grant a partner their own line
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
         WHERE schemaname = 'public' AND tablename = 'profit_distribution_details'
           AND policyname = 'profit_distribution_details_read'
           AND COALESCE(qual, '') ILIKE '%partners%'
    ) THEN
        RAISE EXCEPTION 'FAIL: detail read policy does not let a partner see their own line';
    END IF;

    -- money arithmetic + period CHECKs and the composite FK
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'profit_distributions_math'
                      AND conrelid = 'public.profit_distributions'::regclass) THEN
        RAISE EXCEPTION 'FAIL: header arithmetic CHECK missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'profit_distribution_details_math'
                      AND conrelid = 'public.profit_distribution_details'::regclass) THEN
        RAISE EXCEPTION 'FAIL: detail arithmetic CHECK missing';
    END IF;

    -- no CASCADE anywhere; offending FKs must RESTRICT
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'profit_distributions_farm_id_fkey' AND confdeltype = 'r') THEN
        RAISE EXCEPTION 'FAIL: header.farm_id FK must be ON DELETE RESTRICT';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'profit_distribution_details_partner_id_fkey' AND confdeltype = 'r') THEN
        RAISE EXCEPTION 'FAIL: details.partner_id FK must be ON DELETE RESTRICT';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname IN ('profit_distributions_farm_id_fkey',
                                  'profit_distributions_flock_id_fkey',
                                  'profit_distribution_details_distribution_id_fkey',
                                  'profit_distribution_details_farm_id_fkey',
                                  'profit_distribution_details_partner_id_fkey')
                  AND confdeltype = 'c') THEN
        RAISE EXCEPTION 'FAIL: a W6 profit FK uses ON DELETE CASCADE';
    END IF;

    -- updated_at triggers
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE NOT tgisinternal
       AND tgname IN ('trg_profit_distributions_updated_at', 'trg_pdd_updated_at');
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FAIL: W6 profit updated_at triggers missing';
    END IF;

    -- anon gets nothing; authenticated gets DML; never to PUBLIC
    IF has_table_privilege('anon', 'public.profit_distributions', 'SELECT')
       OR has_table_privilege('anon', 'public.profit_distribution_details', 'SELECT') THEN
        RAISE EXCEPTION 'FAIL: anon can read W6 profit tables';
    END IF;
    IF NOT has_table_privilege('authenticated', 'public.profit_distributions', 'SELECT')
       OR NOT has_table_privilege('authenticated', 'public.profit_distribution_details', 'SELECT') THEN
        RAISE EXCEPTION 'FAIL: authenticated lost table access on W6 profit tables';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
        WHERE n.nspname = 'public'
          AND c.relname IN ('profit_distributions', 'profit_distribution_details')
          AND a.grantee = 0
    ) THEN
        RAISE EXCEPTION 'FAIL: W6 profit tables still grant to PUBLIC (grantee 0)';
    END IF;

    RAISE NOTICE 'OK: M22 verified - profit_distributions + details live, math enforced, RLS manager/partner scoped';
END;
$m22_chk$;
