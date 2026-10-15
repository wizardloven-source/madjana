-- ============================================================================
-- p0_profit_distribution_lifecycle_test.sql
-- W7.3 (M30): create -> approve a profit distribution, and the status guard.
--
--   * system_admin creates      -> header 'draft' + lines 'pending'
--   * the stored math + lines mirror calculate_profit_distribution()
--   * a manager creates         -> allowed on a farm they manage
--   * a manager approves        -> AUTHORIZATION_DENIED
--   * a manager edits status    -> AUTHORIZATION_DENIED (guard trigger)
--   * system_admin approves     -> 'approved' + approved_by/at stamped
--   * re-approve / illegal move -> INVALID_STATUS_TRANSITION
--   * partner_audit carries 'distribution_created' (per line) + 'distribution_approved'
--
-- Runs as the non-superuser `test_runner` inside BEGIN ... ROLLBACK, so RLS
-- actually applies and nothing is left behind.
-- ============================================================================
BEGIN;

CREATE SCHEMA IF NOT EXISTS tests;
CREATE OR REPLACE FUNCTION tests.set_user(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config('request.jwt.claims',
        jsonb_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
END;
$$;
CREATE OR REPLACE FUNCTION tests.assert(p_label text, p_cond boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_cond THEN RAISE NOTICE 'PASS [%] %', p_label, p_detail;
    ELSE RAISE EXCEPTION 'FAIL [%] %', p_label, p_detail; END IF;
END;
$$;

DO $guard$
DECLARE v_super boolean; v_bypass boolean;
BEGIN
    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass FROM pg_roles WHERE rolname = current_user;
    IF v_super OR v_bypass THEN
        RAISE EXCEPTION 'run this suite as test_runner (non-superuser), not as the owner';
    END IF;
END;
$guard$;

DO $lifecycle$
DECLARE
    v_sys   uuid := '00000000-0000-0000-0000-00000000000e';  -- system_admin
    v_mgr   uuid := '00000000-0000-0000-0000-00000000000a';  -- manager of FARM_A
    v_farmA uuid := '00000000-0000-0000-0000-000000000001';
    v_farmB uuid := '00000000-0000-0000-0000-000000000002';

    v_pa uuid := '00000000-0000-0000-0000-00000000a0a1';     -- 50%
    v_pb uuid := '00000000-0000-0000-0000-00000000a0a2';     -- 50%

    v_d1 uuid;   -- admin-created, 2027-03
    v_d2 uuid;   -- manager-created, 2027-04
    v_n  numeric(16,8);
    v_c  int;
    v_s  text;
    v_by uuid;
    v_at timestamptz;
BEGIN
    -- ── setup (as system_admin) ──────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);

    INSERT INTO public.partners (id, name, share_model, percentage, currency) VALUES
        (v_pa, 'Lifecycle A 50', 'percentage', 50, 'dollar'),
        (v_pb, 'Lifecycle B 50', 'percentage', 50, 'dollar');

    INSERT INTO public.revenue (farm_id, date, category, amount, currency)
        VALUES (v_farmA, '2027-03-15', 'other', 2000, 'dollar');
    INSERT INTO public.expenses (farm_id, date, category, amount, currency)
        VALUES (v_farmA, '2027-03-15', 'other', 500, 'dollar');

    -- ── 1) system_admin creates ──────────────────────────────────────────────
    v_d1 := public.create_profit_distribution(
        v_farmA, '2027-03-01', '2027-03-31', NULL, 300, 'LIFECYCLE', NULL);

    SELECT status INTO v_s FROM public.profit_distributions WHERE id = v_d1;
    PERFORM tests.assert('create: header is draft', v_s = 'draft', format('s=%s', v_s));

    SELECT total_revenue INTO v_n FROM public.profit_distributions WHERE id = v_d1;
    PERFORM tests.assert('create: total_revenue = 2000', v_n = 2000, format('v=%s', v_n));
    SELECT total_expenses INTO v_n FROM public.profit_distributions WHERE id = v_d1;
    PERFORM tests.assert('create: total_expenses = 500', v_n = 500, format('v=%s', v_n));
    SELECT net_profit INTO v_n FROM public.profit_distributions WHERE id = v_d1;
    PERFORM tests.assert('create: net_profit = 1500', v_n = 1500, format('v=%s', v_n));
    SELECT distributable_profit INTO v_n FROM public.profit_distributions WHERE id = v_d1;
    PERFORM tests.assert('create: distributable_profit = 1200 (1500-300)', v_n = 1200, format('v=%s', v_n));
    SELECT created_by INTO v_by FROM public.profit_distributions WHERE id = v_d1;
    PERFORM tests.assert('create: created_by = system_admin', v_by = v_sys, '');

    SELECT count(*) INTO v_c FROM public.profit_distribution_details
     WHERE distribution_id = v_d1 AND status = 'pending';
    PERFORM tests.assert('create: 2 lines, all pending', v_c = 2, format('n=%s', v_c));

    SELECT net_amount INTO v_n FROM public.profit_distribution_details
     WHERE distribution_id = v_d1 AND partner_id = v_pa;
    PERFORM tests.assert('create: PA line net_amount = 750', v_n = 750, format('v=%s', v_n));
    SELECT profit_share INTO v_n FROM public.profit_distribution_details
     WHERE distribution_id = v_d1 AND partner_id = v_pb;
    PERFORM tests.assert('create: PB line profit_share = 750', v_n = 750, format('v=%s', v_n));

    SELECT amount INTO v_n FROM public.calculate_profit_distribution(
        v_farmA, '2027-03-01', '2027-03-31', NULL) WHERE partner_id = v_pa;
    PERFORM tests.assert('create: stored line == preview (750)', v_n = 750, format('v=%s', v_n));

    SELECT count(*) INTO v_c FROM public.partner_audit
     WHERE action = 'distribution_created'
       AND new_values->>'distribution_id' = v_d1::text;
    PERFORM tests.assert('audit: one distribution_created PER line (2)', v_c = 2, format('n=%s', v_c));

    -- ── 2) a manager may create on a farm they manage ────────────────────────
    PERFORM tests.set_user(v_mgr);
    v_d2 := public.create_profit_distribution(
        v_farmA, '2027-04-01', '2027-04-30', NULL, 0, 'MGR', NULL);
    SELECT status, created_by INTO v_s, v_by
      FROM public.profit_distributions WHERE id = v_d2;
    PERFORM tests.assert('manager create: draft', v_s = 'draft', format('s=%s', v_s));
    PERFORM tests.assert('manager create: created_by = manager', v_by = v_mgr, '');

    -- manager cannot create on a farm they do not manage
    BEGIN
        PERFORM public.create_profit_distribution(
            v_farmB, '2027-04-01', '2027-04-30', NULL, 0, NULL, NULL);
        PERFORM tests.assert('manager create on foreign farm denied', false, 'allowed');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('manager create on foreign farm denied',
            SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    -- ── 2) manager approving is denied ───────────────────────────────────────
    PERFORM tests.assert('manager approving is denied (pre-check)',
        NOT (SELECT public.is_system_admin()), '');
    BEGIN
        PERFORM public.approve_profit_distribution(v_d1);
        PERFORM tests.assert('manager approve -> AUTHORIZATION_DENIED', false, 'approved!');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('manager approve -> AUTHORIZATION_DENIED',
            SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    -- ── 3) manager cannot change status directly (guard trigger) ─────────────
    BEGIN
        UPDATE public.profit_distributions SET status = 'approved' WHERE id = v_d2;
        PERFORM tests.assert('manager direct status edit denied', false, 'updated!');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('manager direct status edit denied',
            SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    -- manager cannot pre-stamp approver fields either
    BEGIN
        UPDATE public.profit_distributions SET approved_by = v_mgr WHERE id = v_d2;
        PERFORM tests.assert('manager setting approved_by denied', false, 'updated!');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('manager setting approved_by denied',
            SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    -- manager cannot INSERT a non-draft header either
    BEGIN
        INSERT INTO public.profit_distributions
            (farm_id, period_start, period_end, status)
        VALUES (v_farmA, '2028-01-01', '2028-01-31', 'approved');
        PERFORM tests.assert('manager INSERT non-draft denied', false, 'inserted!');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('manager INSERT non-draft denied',
            SQLERRM LIKE '%AUTHORIZATION_DENIED%', SQLERRM);
    END;

    -- ── 4) system_admin approves ─────────────────────────────────────────────
    PERFORM tests.set_user(v_sys);
    PERFORM public.approve_profit_distribution(v_d1);

    SELECT status, approved_by, approved_at INTO v_s, v_by, v_at
      FROM public.profit_distributions WHERE id = v_d1;
    PERFORM tests.assert('approve: status = approved', v_s = 'approved', format('s=%s', v_s));
    PERFORM tests.assert('approve: approved_by = system_admin', v_by = v_sys, '');
    PERFORM tests.assert('approve: approved_at stamped', v_at IS NOT NULL, '');

    SELECT count(*) INTO v_c FROM public.partner_audit
     WHERE action = 'distribution_approved'
       AND new_values->>'distribution_id' = v_d1::text;
    PERFORM tests.assert('approve: audit distribution_approved = 1', v_c = 1, format('n=%s', v_c));

    -- re-approve -> INVALID_STATUS_TRANSITION
    BEGIN
        PERFORM public.approve_profit_distribution(v_d1);
        PERFORM tests.assert('re-approve -> INVALID_STATUS_TRANSITION', false, 'approved again!');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('re-approve -> INVALID_STATUS_TRANSITION',
            SQLERRM LIKE '%INVALID_STATUS_TRANSITION%', SQLERRM);
    END;

    -- admin illegal move approved -> draft -> INVALID_STATUS_TRANSITION
    BEGIN
        UPDATE public.profit_distributions SET status = 'draft' WHERE id = v_d1;
        PERFORM tests.assert('admin illegal transition denied', false, 'moved!');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('admin illegal transition denied',
            SQLERRM LIKE '%INVALID_STATUS_TRANSITION%', SQLERRM);
    END;

    -- ── 5) duplicate + loss + bad reserve guards ─────────────────────────────
    BEGIN
        PERFORM public.create_profit_distribution(
            v_farmA, '2027-03-01', '2027-03-31', NULL, 0, NULL, NULL);
        PERFORM tests.assert('duplicate period -> DISTRIBUTION_EXISTS', false, 'created!');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('duplicate period -> DISTRIBUTION_EXISTS',
            SQLERRM LIKE '%DISTRIBUTION_EXISTS%', SQLERRM);
    END;

    INSERT INTO public.expenses (farm_id, date, category, amount, currency)
        VALUES (v_farmA, '2027-05-10', 'other', 5000, 'dollar');
    BEGIN
        PERFORM public.create_profit_distribution(
            v_farmA, '2027-05-01', '2027-05-31', NULL, 0, NULL, NULL);
        PERFORM tests.assert('loss period -> NEGATIVE_NET_PROFIT', false, 'created!');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('loss period -> NEGATIVE_NET_PROFIT',
            SQLERRM LIKE '%NEGATIVE_NET_PROFIT%', SQLERRM);
    END;

    BEGIN
        PERFORM public.create_profit_distribution(
            v_farmA, '2027-06-01', '2027-06-30', NULL, -1, NULL, NULL);
        PERFORM tests.assert('negative reserve -> INVALID_RESERVE', false, 'created!');
    EXCEPTION WHEN others THEN
        PERFORM tests.assert('negative reserve -> INVALID_RESERVE',
            SQLERRM LIKE '%INVALID_RESERVE%', SQLERRM);
    END;

    RAISE NOTICE 'p0_profit_distribution_lifecycle: انتهى';
END;
$lifecycle$;

DO $final$ BEGIN
    RAISE NOTICE 'p0_profit_distribution_lifecycle: كل الفحوص PASS';
END; $final$;

ROLLBACK;
