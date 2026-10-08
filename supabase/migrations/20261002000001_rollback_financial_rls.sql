-- ═════════════════════════════════════════════════════════════════════════════
-- M8 ROLLBACK — undo 20261002000000_restore_financial_rls.sql
-- ═════════════════════════════════════════════════════════════════════════════
--  To undo M8, run THIS file:
--      psql -f supabase/migrations/20261002000001_rollback_financial_rls.sql
--
--  WHAT IT DOES — and why read this before running.
--  The forward migration made the six financial tables manager-only. This
--  rollback reverses that: it restores the pre-M8 policy shape exactly as
--  `20260926000800_farm_membership_authorization.sql` left it —
--
--      <table>_read    SELECT  USING     user_has_farm_access(farm_id)
--      <table>_insert  INSERT  WITH CHECK user_has_farm_access(farm_id)
--      <table>_update  UPDATE  USING/WC   user_has_farm_access(farm_id)
--      <table>_delete  DELETE  USING     user_manages_farm(farm_id)
--
--  on payments, expenses, revenue, opening_balances, inventory_items and
--  stock_adjustments — and nothing else.
--
--  ⚠ REWEAKENS SECURITY. user_has_farm_access() returns true for ANY member
--    of user_farms — a worker included. Running this rollback reopens the
--    SEC-002 hole that 20261002000000 closed: a worker can again read, insert
--    and update the money rows of their farm through the REST API. The guard
--    test p0_financial_rls_guard_test.sql FAILS against the result of this
--    file, which is correct behaviour, not a bug:
--        p0_financial_rls_guard_test: كل الفحوص PASS  →  forward is live
--        FAIL ... deployments  →  this rollback has been applied
--    Roll back only if M8 must be withdrawn, and prefer rolling back on a
--    test database or right after a fresh dump. The weakened shape is applied
--    blindly here: like the forward, every policy on the six tables is dropped
--    first, so this file cannot leave a single permissive policy behind — that
--    is the guarantee the end-of-file verification block re-checks.
--
--  TABLES IN SCOPE: payments, expenses, revenue, opening_balances,
--                    inventory_items, stock_adjustments.
--  NO table outside that list is touched. Policy *names* are not referenced
--  except in the DROP loop, because PostgreSQL ORs every matching policy for
--  a command: a name-targeted DROP would let a differently-named leftover
--  policy silently survive.
--
--  RE-RUN SAFE: every statement is IF EXISTS / inside a drop-all loop.
-- ═════════════════════════════════════════════════════════════════════════════

BEGIN;

SET LOCAL lock_timeout = '10s';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Enumerate the six tables, drop EVERY policy on each, then recreate the
--    pre-M8 (00800) membership-scoped shape.
-- ─────────────────────────────────────────────────────────────────────────────
DO $rollback$
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

        -- Drop EVERY policy on this table. See the header note: any surviving
        -- permissive policy would silently defeat the recreate below.
        FOR v_pol IN
            SELECT policyname
              FROM pg_policies
             WHERE schemaname = 'public' AND tablename = t
        LOOP
            EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',
                           v_pol.policyname, t);
            RAISE NOTICE 'dropped % on public.%', v_pol.policyname, t;
        END LOOP;

        -- ── Recreate: the exact 00800 weakened shape (M8 reverses this) ─────
        EXECUTE format($preM8$
            CREATE POLICY %1$I_read ON public.%1$I
                FOR SELECT TO authenticated
                USING (public.user_has_farm_access(farm_id));

            CREATE POLICY %1$I_insert ON public.%1$I
                FOR INSERT TO authenticated
                WITH CHECK (public.user_has_farm_access(farm_id));

            CREATE POLICY %1$I_update ON public.%1$I
                FOR UPDATE TO authenticated
                USING (public.user_has_farm_access(farm_id))
                WITH CHECK (public.user_has_farm_access(farm_id));

            CREATE POLICY %1$I_delete ON public.%1$I
                FOR DELETE TO authenticated
                USING (public.user_manages_farm(farm_id));
        $preM8$, t);

        RAISE NOTICE 'restored pre-M8 (00800) shape on public.%', t;
    END LOOP;
END
$rollback$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Verification — assert the rollback actually produced the pre-M8 shape:
--    read/insert/update are membership-scoped and delete is manager-scoped,
--    on all six tables, granted to authenticated only. Hard fail otherwise.
-- ─────────────────────────────────────────────────────────────────────────────
DO $rollback_verify$
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
        v_seen := 0;

        FOR p IN
            SELECT policyname, cmd, roles::text AS roles_txt,
                   coalesce(qual, '') AS q,
                   coalesce(with_check, '') AS wc
              FROM pg_policies
             WHERE schemaname = 'public' AND tablename = t
        LOOP
            -- Effective predicate: INSERT is gated by WITH CHECK, every other
            -- command by USING (and its WITH CHECK on UPDATE).
            v_pred := CASE WHEN p.cmd = 'INSERT' THEN p.wc
                           ELSE p.q || ' ' || p.wc END;

            IF v_pred = '' THEN
                RAISE EXCEPTION
                    'ABORT: public.% policy % (%) has no predicate after the rollback.',
                    t, p.policyname, p.cmd;
            END IF;

            -- The pre-M8 shape: DELETE is manager-scoped, the rest membership-
            -- scoped. Anything else means the rollback did not faithfully undo.
            IF p.cmd = 'DELETE' THEN
                IF v_pred NOT ILIKE '%user_manages_farm%' THEN
                    RAISE EXCEPTION
                        'ABORT: public.% policy % (DELETE) is not manager-scoped: %',
                        t, p.policyname, left(v_pred, 200);
                END IF;
            ELSIF v_pred NOT ILIKE '%user_has_farm_access%' THEN
                RAISE EXCEPTION
                    'ABORT: public.% policy % (%) is not membership-scoped: %',
                    t, p.policyname, p.cmd, left(v_pred, 200);
            END IF;

            -- `TO public` is as fatal as `TO anon` and is NOT caught by testing
            -- for 'anon' alone, because the roles array then reads {public}.
            IF position('anon' in p.roles_txt) > 0
               OR position('public' in p.roles_txt) > 0 THEN
                RAISE EXCEPTION
                    'ABORT: public.% policy % (%) is granted to % (must be authenticated only).',
                    t, p.policyname, p.cmd, p.roles_txt;
            END IF;

            v_seen := v_seen + 1;
            RAISE NOTICE 'verified: public.%  %  %  -> pre-M8 shape',
                         t, p.cmd, p.policyname;
        END LOOP;

        IF v_seen <> 4 THEN
            RAISE EXCEPTION
                'ABORT: public.% has % policies after the rollback (expected 4).',
                t, v_seen;
        END IF;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE 'VERIFIED — all policies on the six financial tables are back to the pre-M8 (00800) shape.';
    RAISE NOTICE 'NOTE — this is the weakened state. Re-apply 20261002000000 to restore the M8 manager-only guard.';
END
$rollback_verify$;

COMMIT;

-- ============================================================================
--  Post-application checklist:
--
--    1. SELECT * FROM pg_policies
--        WHERE tablename IN ('payments','expenses','revenue',
--                            'opening_balances','inventory_items','stock_adjustments');
--       → expect `*_read / *_insert / *_update` referencing
--         user_has_farm_access(farm_id) and `*_delete` referencing
--         user_manages_farm(farm_id).
--
--    2. Confirm the danger is understood before staying here: a worker can now
--       SELECT / INSERT / UPDATE the money rows of their farm. Re-apply
--       20261002000000_restore_financial_rls.sql as soon as the withdrawal is
--       no longer needed.
-- ============================================================================