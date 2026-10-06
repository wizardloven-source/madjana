-- ============================================================================
--  20261002000000_restore_financial_rls.sql
--  Fix P0 — restore manager-scoped RLS on the financial tables.
-- ============================================================================
--
--  WHY THIS MIGRATION EXISTS (P0 — see ANALYSIS_REPORT.md § 7.1)
--  ───────────────────────────────────────────────────────────────────────────
--  Migration 20260926000800_farm_membership_authorization.sql intended to
--  replace role-based policies with farm-membership-based ones. For the
--  OPERATIONAL tables that was correct and an improvement.
--
--  For the FINANCIAL tables it was a REGRESSION. Before that migration the
--  policies were manager-gated:
--
--      payments_manager_farm_scoped ON payments FOR ALL TO authenticated
--      USING (is_system_admin() OR (current_user_role() = 'manager'
--                                   AND farm_id = current_user_farm_id()))
--      -- same shape on expenses, revenue, opening_balances,
--      --              inventory_items, stock_adjustments  (init.sql:5141-5189)
--
--  00800 first DROPPED every existing policy on 16 tables (lines 254-261),
--  then re-created them (lines 284-301) using:
--
--      SELECT / INSERT / UPDATE  ->  public.user_has_farm_access(farm_id)
--      DELETE                    ->  public.user_manages_farm(farm_id)
--
--  and user_has_farm_access() (00800:48-64) returns true for ANY row in
--  user_farms — which includes workers. The manager-gate was therefore lost:
--  a worker could SELECT / INSERT / UPDATE payments, expenses, revenue,
--  opening_balances and inventory_items directly through the REST API
--  (supabase_payment_datasource.dart:15,31,39,43 and siblings), because
--  init.sql:1139 and init.sql:1161-1164 GRANT those verbs to `authenticated`.
--
--  This contradicts docs/SECURITY_AUDIT.md § 4 ("Financial tables
--  manager-only"), which is now factually wrong about production.
--
--  Note the app was never the hole. sync_can_write(role, table)
--  (20260926000100:179-215) already excludes workers from FIVE of these six
--  tables — payments, expenses, opening_balances, inventory_items and
--  stock_adjustments. The sixth, revenue, is still in the worker write list,
--  so the app currently permits a worker to push a revenue row that this
--  migration will then reject at the database.
--
--  That disagreement is deliberate here, and is a behaviour change worth
--  knowing about before you apply it: no mobile or desktop code writes
--  revenue (the only revenue screen, desktop
--  revenue_screen.dart, is manager-gated), so nothing in this repo regresses.
--  But a worker with a queued offline revenue record, or any third-party
--  client written against sync_can_write, will start getting an RLS error on
--  flush instead of a silent write. Check the Sync Center for pending
--  revenue writes from workers before deploying, or relax the revenue policy
--  back to membership-scoped if worker revenue entry is intentional.
--
--  WHAT IT DOES
--  ───────────
--  For exactly these six tables — and nothing else in the schema — it drops
--  ALL policies and recreates four manager-scoped ones per table.
--
--  Dropping *all* policies (rather than only the four names 00800 created)
--  is deliberate and necessary: PostgreSQL ORs together every policy that
--  matches a given (role, command). A single surviving permissive policy
--  would silently re-open the hole, so a name-targeted DROP is not safe
--  here. The end-of-file verification block then proves no permissive
--  policy remains, so a future 00800-style migration cannot quietly
--  reintroduce this without the verification failing.
--
--  TABLES IN SCOPE: payments, expenses, revenue, opening_balances,
--                    inventory_items, stock_adjustments.
--  NO table outside that list is touched. Within those six tables, every
--  pre-existing policy is dropped — including any that a future migration
--  adds with an unrelated name, which is the point.
--
--  RE-RUN SAFE: every statement is IF EXISTS / OR REPLACE.
--
--  ONE CAVEAT, because it will silently invalidate any test that "passes":
--  these tables are RLS-enabled but NOT FORCE RLS, so the table OWNER still
--  bypasses every policy below. Supabase PostgREST connects as `authenticated`,
--  so production is genuinely protected — but a test run as the owner
--  (`postgres`) will see all rows and falsely report the hole still open, or
--  falsely report it closed. p0_financial_rls_guard_test.sql therefore asserts
--  rolsuper = false and rolbypassrls = false before it trusts its own results.
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Enumerate the six tables
-- ─────────────────────────────────────────────────────────────────────────────
DO $scope$
DECLARE
    v_tables text[] := ARRAY[
        'payments', 'expenses', 'revenue',
        'opening_balances', 'inventory_items', 'stock_adjustments'
    ];
    t text;
    v_pol record;
BEGIN
    FOREACH t IN ARRAY v_tables LOOP
        IF to_regclass('public.' || t) IS NULL THEN
            RAISE EXCEPTION
                'ABORT: public.% is missing. init.sql must be applied first.', t;
        END IF;

        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);

        -- Drop EVERY policy on this table. See the header note: policies for the
        -- same command are OR-ed together, so any leftover permissive policy
        -- would defeat the recreate below.
        -- The DROP loop used to be a nested DO block BUILT as text by the
        -- outer format(), with a second format() inside it. Escaping percent
        -- signs through two format() layers is what made this file fail
        -- three separate ways ("too few arguments", then "unrecognized
        -- format() type specifier"). It is now a plain FOR loop over
        -- pg_policies, executed directly: no generated text, no %% escaping,
        -- nothing to get wrong. %I quotes identifiers, so a table or policy
        -- name with unusual characters cannot break out of the statement.
        FOR v_pol IN
            SELECT policyname
              FROM pg_policies
             WHERE schemaname = 'public' AND tablename = t
        LOOP
            EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',
                           v_pol.policyname, t);
            RAISE NOTICE 'dropped % on public.%', v_pol.policyname, t;
        END LOOP;

        -- ── Recreate: manager-scoped for every verb ──────────────────────────
        -- user_manages_farm() already ORs in is_system_admin() (00800:74-84);
        -- it is spelled out here anyway so the predicate keeps its meaning even
        -- if that helper is ever redefined.
        EXECUTE format($pol$
            CREATE POLICY %1$I_read ON public.%1$I
                FOR SELECT TO authenticated
                USING (public.is_system_admin()
                       OR public.user_manages_farm(farm_id));

            CREATE POLICY %1$I_insert ON public.%1$I
                FOR INSERT TO authenticated
                WITH CHECK (public.is_system_admin()
                            OR public.user_manages_farm(farm_id));

            CREATE POLICY %1$I_update ON public.%1$I
                FOR UPDATE TO authenticated
                USING (public.is_system_admin()
                       OR public.user_manages_farm(farm_id))
                WITH CHECK (public.is_system_admin()
                            OR public.user_manages_farm(farm_id));

            CREATE POLICY %1$I_delete ON public.%1$I
                FOR DELETE TO authenticated
                USING (public.is_system_admin()
                       OR public.user_manages_farm(farm_id));
        $pol$, t);

        RAISE NOTICE 'restored manager-scoped RLS on public.%', t;
    END LOOP;
END
$scope$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Verification — hard fail if any permissive policy survives on the six
--    tables. This is the guard that stops a future membership-scoped
--    migration from reopening the hole in silence.
-- ─────────────────────────────────────────────────────────────────────────────
DO $verify$
DECLARE
    v_tables text[] := ARRAY[
        'payments', 'expenses', 'revenue',
        'opening_balances', 'inventory_items', 'stock_adjustments'
    ];
    t text;
    p record;
    v_pred text;
    v_seen int;
BEGIN
    FOREACH t IN ARRAY v_tables LOOP
        -- Reset per table: a cumulative counter would let an empty table slip
        -- through the "no policies" check below whenever an earlier table had
        -- contributed some.
        v_seen := 0;

        FOR p IN
            SELECT policyname, cmd, roles::text AS roles_txt,
                   coalesce(qual, '') AS q,
                   coalesce(with_check, '') AS wc
              FROM pg_policies
             WHERE schemaname = 'public' AND tablename = t
        LOOP
            -- Effective predicate: INSERT is gated by WITH CHECK, every other
            -- command by USING. Both are checked so an INSERT-only hole cannot
            -- hide behind a null `qual`.
            v_pred := CASE WHEN p.cmd = 'INSERT' THEN p.wc
                           ELSE p.q || ' ' || p.wc END;

            IF v_pred = '' THEN
                RAISE EXCEPTION
                    'ABORT: public.% policy % (%) has no predicate — it allows every row.',
                    t, p.policyname, p.cmd;
            END IF;

            IF v_pred NOT ILIKE '%user_manages_farm%'
               AND v_pred NOT ILIKE '%system_admin%' THEN
                RAISE EXCEPTION
                    'ABORT: public.% policy % (%) is not manager-gated: %',
                    t, p.policyname, p.cmd, left(v_pred, 200);
            END IF;

            -- anon must never read money. `TO public` is equally fatal and is
            -- NOT caught by testing for 'anon' alone, because the roles array
            -- then reads {public} and never names anon — so check both.
            IF position('anon' in p.roles_txt) > 0
               OR position('public' in p.roles_txt) > 0 THEN
                RAISE EXCEPTION
                    'ABORT: public.% policy % (%) is granted to % (must be authenticated only).',
                    t, p.policyname, p.cmd, p.roles_txt;
            END IF;

            v_seen := v_seen + 1;
            RAISE NOTICE 'verified: public.%  %  %  -> manager-gated',
                         t, p.cmd, p.policyname;
        END LOOP;

        IF v_seen = 0 THEN
            RAISE EXCEPTION 'ABORT: public.% has no policies at all after the fix.', t;
        END IF;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE 'VERIFIED — all policies on the six financial tables are manager-scoped.';
END
$verify$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Optional follow-up, NOT applied here.
--
--    `customers` was weakened by the same migration and is not in the six
--    tables this file was scoped to. 00800:316-333 gives workers
--    SELECT / INSERT / UPDATE on customers via user_has_farm_access(farm_id).
--    A worker can therefore read and edit the customer book of their farm
--    through the REST API, even though sync_can_write correctly denies it.
--
--    Run this only after deciding that customers should be manager-only:
--
--      BEGIN;
--      DROP POLICY IF EXISTS op_select ON public.customers;
--      DROP POLICY IF EXISTS op_insert ON public.customers;
--      DROP POLICY IF EXISTS op_update ON public.customers;
--      DROP POLICY IF EXISTS op_delete ON public.customers;
--
--      CREATE POLICY customers_read ON public.customers FOR SELECT TO authenticated
--          USING (public.is_system_admin() OR is_global
--                 OR public.user_manages_farm(farm_id));
--      CREATE POLICY customers_insert ON public.customers FOR INSERT TO authenticated
--          WITH CHECK (public.is_system_admin() OR public.user_manages_farm(farm_id));
--      CREATE POLICY customers_update ON public.customers FOR UPDATE TO authenticated
--          USING (public.is_system_admin() OR public.user_manages_farm(farm_id))
--          WITH CHECK (public.is_system_admin()
--                      OR (NOT is_global AND public.user_manages_farm(farm_id)));
--      CREATE POLICY customers_delete ON public.customers FOR DELETE TO authenticated
--          USING (public.is_system_admin() OR public.user_manages_farm(farm_id));
--      COMMIT;
--
--    The `NOT is_global` term in the UPDATE policy is the part that is easy to
--    lose: without it, a manager could promote a customer to global and leak
--    it into every farm.
-- ─────────────────────────────────────────────────────────────────────────────

COMMIT;

-- ============================================================================
--  Post-apply checklist (run each of these by hand, see p0_financial_rls_
--  guard_test.sql for the automated version):
--
--    1. SELECT * FROM pg_policies
--        WHERE tablename IN ('payments','expenses','revenue',
--                            'opening_balances','inventory_items','stock_adjustments');
--       → expect only *_read/_insert/_update/_delete, all referencing
--         user_manages_farm or is_system_admin.
--
--    2. Log in as a real worker, then:
--         curl "$SUPABASE_URL/rest/v1/payments?select=*&farm_id=eq.<FARM>" \
--              -H "apikey: $ANON" -H "Authorization: Bearer $WORKER_JWT"
--       → expect [] , HTTP 200 (RLS hides rows, it does not 403).
--
--    3. Same JWT, attempt an insert:
--         curl -X POST "$SUPABASE_URL/rest/v1/expenses" ... -d '{...}'
--       → expect HTTP 403 with "row-level security".
--
--    4. Log in as the farm's manager and confirm the farm's own financial
--       screens (Dispatch / Payments / Expenses / Revenue / Inventory) still
--       load and still save.
--
--    5. Confirm the desktop 30-second sync loop still reports 0 failures in
--       Sync Center — sync_records_batch writes as the calling user, so a
--       wrongly tightened policy would show up there immediately.
-- ============================================================================