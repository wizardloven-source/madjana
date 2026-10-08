-- ============================================================================
-- P0 M5: validate_flock_farm coverage + trg_require_farm_id
-- ============================================================================
-- The rules under test, from docs/SECURITY.md:
--   * a row naming a flock of ANOTHER farm is REJECTED on every table
--     that carries flock_id: egg_dispatch, feed_received,
--     stock_adjustments, expenses, medications
--   * flock_id NULL is ACCEPTED (farm-level rows must keep working)
--   * farm_id NULL is REJECTED on the same five tables
--   * validate_flock_farm() still holds its cross-farm body, and no stray
--     trigger sits on flocks
--   * the migration's DDL re-runs cleanly (idempotent)
--
-- Runs inside BEGIN/ROLLBACK. Fixtures from local_fixtures.sql.
--   psql -f supabase/tests/p0_validate_flock_farm_coverage_test.sql
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS tests;

CREATE OR REPLACE FUNCTION tests.set_user(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
        true);
END;
$$;

CREATE OR REPLACE FUNCTION tests.expect(
    p_label text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok THEN
        RAISE NOTICE 'PASS  %', rpad(p_label, 56, '.');
    ELSE
        RAISE EXCEPTION 'FAIL  %  %', p_label, p_detail;
    END IF;
END;
$$;

DO $$
DECLARE
    v_farm_a  uuid := '00000000-0000-0000-0000-000000000001';
    v_farm_b  uuid := '00000000-0000-0000-0000-000000000002';
    v_admin_a uuid := '00000000-0000-0000-0000-00000000000a';
    v_sysadm  uuid := '00000000-0000-0000-0000-00000000000e';
    v_flock_a uuid;
    v_flock_b uuid;
    v_cust    uuid;
    v_row     uuid;
BEGIN
    -- ── setup ────────────────────────────────────────────────────────────
    -- system_admin for fixtures: FARM_B's flock must exist, and only a
    -- sysadmin passes user_has_farm_access() for a farm that is not the
    -- caller's own.
    PERFORM tests.set_user(v_sysadm);

    INSERT INTO public.flocks (farm_id, breed, initial_count, current_count,
                               start_date, status)
    VALUES (v_farm_a, 'M5 Flock A', 500, 500, CURRENT_DATE - 30, 'active'),
           (v_farm_b, 'M5 Flock B', 400, 400, CURRENT_DATE - 30, 'active');
    SELECT id INTO v_flock_a FROM public.flocks
     WHERE farm_id = v_farm_a AND breed = 'M5 Flock A';
    SELECT id INTO v_flock_b FROM public.flocks
     WHERE farm_id = v_farm_b AND breed = 'M5 Flock B';

    INSERT INTO public.customers (farm_id, name, phone)
    VALUES (v_farm_a, 'M5 Customer', '0555000001')
    RETURNING id INTO v_cust;

    -- every behavioural assertion below runs as manager A
    PERFORM tests.set_user(v_admin_a);

    -- ── 1. structural: cross-farm validate triggers (5) ──────────────────
    PERFORM tests.expect('trg_validate_flock_dispatch installed',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.egg_dispatch'::regclass
                   AND tgname = 'trg_validate_flock_dispatch'
                   AND NOT tgisinternal));
    PERFORM tests.expect('trg_validate_flock_feed_recv installed',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.feed_received'::regclass
                   AND tgname = 'trg_validate_flock_feed_recv'
                   AND NOT tgisinternal));
    PERFORM tests.expect('trg_validate_flock_sa installed',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.stock_adjustments'::regclass
                   AND tgname = 'trg_validate_flock_sa'
                   AND NOT tgisinternal));
    PERFORM tests.expect('trg_validate_flock_expenses installed',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.expenses'::regclass
                   AND tgname = 'trg_validate_flock_expenses'
                   AND NOT tgisinternal));
    PERFORM tests.expect('trg_validate_flock_med installed',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.medications'::regclass
                   AND tgname = 'trg_validate_flock_med'
                   AND NOT tgisinternal));

    -- ── 2. structural: require_farm_id triggers (5) ─────────────────────
    PERFORM tests.expect('trg_require_farm_id on egg_dispatch',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.egg_dispatch'::regclass
                   AND tgname = 'trg_require_farm_id' AND NOT tgisinternal));
    PERFORM tests.expect('trg_require_farm_id on feed_received',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.feed_received'::regclass
                   AND tgname = 'trg_require_farm_id' AND NOT tgisinternal));
    PERFORM tests.expect('trg_require_farm_id on stock_adjustments',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.stock_adjustments'::regclass
                   AND tgname = 'trg_require_farm_id' AND NOT tgisinternal));
    PERFORM tests.expect('trg_require_farm_id on expenses',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.expenses'::regclass
                   AND tgname = 'trg_require_farm_id' AND NOT tgisinternal));
    PERFORM tests.expect('trg_require_farm_id on medications',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.medications'::regclass
                   AND tgname = 'trg_require_farm_id' AND NOT tgisinternal));
    -- ── 3. cross-farm flock REJECTED on all five tables ──────────────────
    BEGIN
        INSERT INTO public.egg_dispatch
            (farm_id, flock_id, date, customer_id, worker_id)
        VALUES (v_farm_a, v_flock_b, CURRENT_DATE, v_cust, v_admin_a);
        PERFORM tests.expect('egg_dispatch cross-farm flock rejected',
            false, 'insert accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('egg_dispatch cross-farm flock rejected',
            SQLERRM LIKE '%لا تنتمي%', SQLERRM);
    END;

    BEGIN
        INSERT INTO public.feed_received
            (farm_id, flock_id, date, entry_mode, quantity, quantity_kg,
             feed_type, worker_id)
        VALUES (v_farm_a, v_flock_b, CURRENT_DATE, 'kg', 10, 10,
                'main', v_admin_a);
        PERFORM tests.expect('feed_received cross-farm flock rejected',
            false, 'insert accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('feed_received cross-farm flock rejected',
            SQLERRM LIKE '%لا تنتمي%', SQLERRM);
    END;

    BEGIN
        INSERT INTO public.stock_adjustments
            (farm_id, flock_id, stock_type, delta_qty, manager_id)
        VALUES (v_farm_a, v_flock_b, 'feed', -2, v_admin_a);
        PERFORM tests.expect('stock_adjustments cross-farm flock rejected',
            false, 'insert accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('stock_adjustments cross-farm flock rejected',
            SQLERRM LIKE '%لا تنتمي%', SQLERRM);
    END;

    BEGIN
        INSERT INTO public.expenses
            (farm_id, flock_id, category, amount, currency)
        VALUES (v_farm_a, v_flock_b, 'feed', 10.00, 'dollar');
        PERFORM tests.expect('expenses cross-farm flock rejected',
            false, 'insert accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('expenses cross-farm flock rejected',
            SQLERRM LIKE '%لا تنتمي%', SQLERRM);
    END;

    BEGIN
        INSERT INTO public.medications
            (farm_id, flock_id, date, type, medicine_name, dosage,
             administration_route, worker_id)
        VALUES (v_farm_a, v_flock_b, CURRENT_DATE, 'drug', 'M5 Med', '1ml',
                'water', v_admin_a);
        PERFORM tests.expect('medications cross-farm flock rejected',
            false, 'insert accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('medications cross-farm flock rejected',
            SQLERRM LIKE '%لا تنتمي%', SQLERRM);
    END;

    -- ── 4. farm_id NULL REJECTED on all five tables ──────────────────────
    BEGIN
        INSERT INTO public.egg_dispatch (farm_id, date, customer_id, worker_id)
        VALUES (NULL, CURRENT_DATE, v_cust, v_admin_a);
        PERFORM tests.expect('egg_dispatch farm_id NULL rejected',
            false, 'insert accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('egg_dispatch farm_id NULL rejected',
            SQLERRM LIKE 'farm_id is required%', SQLERRM);
    END;

    BEGIN
        INSERT INTO public.feed_received
            (farm_id, date, entry_mode, quantity, quantity_kg,
             feed_type, worker_id)
        VALUES (NULL, CURRENT_DATE, 'kg', 10, 10, 'main', v_admin_a);
        PERFORM tests.expect('feed_received farm_id NULL rejected',
            false, 'insert accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('feed_received farm_id NULL rejected',
            SQLERRM LIKE 'farm_id is required%', SQLERRM);
    END;

    BEGIN
        INSERT INTO public.stock_adjustments
            (farm_id, stock_type, delta_qty, manager_id)
        VALUES (NULL, 'feed', -2, v_admin_a);
        PERFORM tests.expect('stock_adjustments farm_id NULL rejected',
            false, 'insert accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('stock_adjustments farm_id NULL rejected',
            SQLERRM LIKE 'farm_id is required%', SQLERRM);
    END;

    BEGIN
        INSERT INTO public.expenses (farm_id, category, amount, currency)
        VALUES (NULL, 'feed', 10.00, 'dollar');
        PERFORM tests.expect('expenses farm_id NULL rejected',
            false, 'insert accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('expenses farm_id NULL rejected',
            SQLERRM LIKE 'farm_id is required%', SQLERRM);
    END;

    BEGIN
        INSERT INTO public.medications
            (farm_id, date, type, medicine_name, dosage,
             administration_route, worker_id)
        VALUES (NULL, CURRENT_DATE, 'drug', 'M5 Med', '1ml',
                'water', v_admin_a);
        PERFORM tests.expect('medications farm_id NULL rejected',
            false, 'insert accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('medications farm_id NULL rejected',
            SQLERRM LIKE 'farm_id is required%', SQLERRM);
    END;
    -- ── 5. flock_id NULL ACCEPTED on all five tables ─────────────────────
    INSERT INTO public.egg_dispatch
        (farm_id, date, customer_id, worker_id)
    VALUES (v_farm_a, CURRENT_DATE, v_cust, v_admin_a)
    RETURNING id INTO v_row;
    PERFORM tests.expect('egg_dispatch flock_id NULL accepted',
        v_row IS NOT NULL);

    INSERT INTO public.feed_received
        (farm_id, date, entry_mode, quantity, quantity_kg,
         feed_type, worker_id)
    VALUES (v_farm_a, CURRENT_DATE, 'kg', 10, 10, 'main', v_admin_a)
    RETURNING id INTO v_row;
    PERFORM tests.expect('feed_received flock_id NULL accepted',
        v_row IS NOT NULL);

    INSERT INTO public.stock_adjustments
        (farm_id, stock_type, delta_qty, manager_id)
    VALUES (v_farm_a, 'feed', -2, v_admin_a)
    RETURNING id INTO v_row;
    PERFORM tests.expect('stock_adjustments flock_id NULL accepted',
        v_row IS NOT NULL);

    INSERT INTO public.expenses
        (farm_id, category, amount, currency)
    VALUES (v_farm_a, 'feed', 10.00, 'dollar')
    RETURNING id INTO v_row;
    PERFORM tests.expect('expenses flock_id NULL accepted',
        v_row IS NOT NULL);

    INSERT INTO public.medications
        (farm_id, date, type, medicine_name, dosage,
         administration_route, worker_id)
    VALUES (v_farm_a, CURRENT_DATE, 'drug', 'M5 Med', '1ml',
            'water', v_admin_a)
    RETURNING id INTO v_row;
    PERFORM tests.expect('medications flock_id NULL accepted',
        v_row IS NOT NULL);

    -- ── 6. same-farm flock ACCEPTED ──────────────────────────────────────
    INSERT INTO public.expenses
        (farm_id, flock_id, category, amount, currency)
    VALUES (v_farm_a, v_flock_a, 'feed', 25.00, 'dollar')
    RETURNING id INTO v_row;
    PERFORM tests.expect('expenses same-farm flock accepted',
        v_row IS NOT NULL);

    -- ── 7. nonexistent flock REJECTED (validate raises before the FK) ────
    BEGIN
        INSERT INTO public.expenses
            (farm_id, flock_id, category, amount, currency)
        VALUES (v_farm_a, '00000000-0000-0000-0000-0000000000ff',
                'feed', 1.00, 'dollar');
        PERFORM tests.expect('nonexistent flock rejected',
            false, 'insert accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('nonexistent flock rejected',
            SQLERRM LIKE '%غير موجودة%', SQLERRM);
    END;

    -- ── 8. cross-farm UPDATE REJECTED ────────────────────────────────────
    BEGIN
        UPDATE public.expenses SET flock_id = v_flock_b
         WHERE farm_id = v_farm_a AND flock_id = v_flock_a;
        PERFORM tests.expect('cross-farm UPDATE rejected',
            false, 'update accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('cross-farm UPDATE rejected',
            SQLERRM LIKE '%لا تنتمي%', SQLERRM);
    END;

    -- ── 9. the guard itself is intact ────────────────────────────────────
    PERFORM tests.expect('no stray trigger on flocks',
        NOT EXISTS (SELECT 1 FROM pg_trigger
                     WHERE tgrelid = 'public.flocks'::regclass
                       AND tgname = 'trg_validate_flock_farm'
                       AND NOT tgisinternal));
    PERFORM tests.expect('validate_flock_farm body still cross-farm',
        EXISTS (SELECT 1 FROM pg_proc
                 WHERE proname = 'validate_flock_farm'
                   AND prosrc LIKE '%لا تنتمي%'));
    PERFORM tests.expect('require_farm_id() exists',
        EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'require_farm_id'));

    RAISE NOTICE 'M5 behavioural block passed';
END $$;
-- ── 10. idempotency: re-run M5's DDL exactly as the migration does ────────
-- test_runner has no TRIGGER privilege on the tables (verified), and the
-- migration itself runs as an owner -- so switch to the session's real
-- role for the re-run, exactly as psql would.
SET ROLE postgres;

CREATE OR REPLACE FUNCTION public.validate_flock_farm()
RETURNS TRIGGER AS $fn$
DECLARE
    v_farm_id uuid;
BEGIN
    IF NEW.flock_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT farm_id INTO v_farm_id FROM flocks WHERE id = NEW.flock_id;
    IF v_farm_id IS NULL THEN
        RAISE EXCEPTION 'الدجاجة غير موجودة: %', NEW.flock_id;
    END IF;
    IF v_farm_id != NEW.farm_id THEN
        RAISE EXCEPTION 'الدجاجة لا تنتمي لهذه المزرعة';
    END IF;
    RETURN NEW;
END;
$fn$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_validate_flock_farm ON public.flocks;
DROP INDEX IF EXISTS public.idx_flocks_active;

DROP TRIGGER IF EXISTS trg_validate_flock_dispatch ON public.egg_dispatch;
CREATE TRIGGER trg_validate_flock_dispatch
    BEFORE INSERT OR UPDATE ON public.egg_dispatch
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_feed_recv ON public.feed_received;
CREATE TRIGGER trg_validate_flock_feed_recv
    BEFORE INSERT OR UPDATE ON public.feed_received
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_sa ON public.stock_adjustments;
CREATE TRIGGER trg_validate_flock_sa
    BEFORE INSERT OR UPDATE ON public.stock_adjustments
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_expenses ON public.expenses;
CREATE TRIGGER trg_validate_flock_expenses
    BEFORE INSERT OR UPDATE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_med ON public.medications;
CREATE TRIGGER trg_validate_flock_med
    BEFORE INSERT OR UPDATE ON public.medications
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

CREATE OR REPLACE FUNCTION public.require_farm_id()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
    IF NEW.farm_id IS NULL THEN
        RAISE EXCEPTION 'farm_id is required (table %)', TG_TABLE_NAME;
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_require_farm_id ON public.egg_dispatch;
CREATE TRIGGER trg_require_farm_id
    BEFORE INSERT OR UPDATE ON public.egg_dispatch
    FOR EACH ROW EXECUTE FUNCTION public.require_farm_id();

DROP TRIGGER IF EXISTS trg_require_farm_id ON public.feed_received;
CREATE TRIGGER trg_require_farm_id
    BEFORE INSERT OR UPDATE ON public.feed_received
    FOR EACH ROW EXECUTE FUNCTION public.require_farm_id();

DROP TRIGGER IF EXISTS trg_require_farm_id ON public.stock_adjustments;
CREATE TRIGGER trg_require_farm_id
    BEFORE INSERT OR UPDATE ON public.stock_adjustments
    FOR EACH ROW EXECUTE FUNCTION public.require_farm_id();

DROP TRIGGER IF EXISTS trg_require_farm_id ON public.expenses;
CREATE TRIGGER trg_require_farm_id
    BEFORE INSERT OR UPDATE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.require_farm_id();

DROP TRIGGER IF EXISTS trg_require_farm_id ON public.medications;
CREATE TRIGGER trg_require_farm_id
    BEFORE INSERT OR UPDATE ON public.medications
    FOR EACH ROW EXECUTE FUNCTION public.require_farm_id();

DO $$
BEGIN
    PERFORM tests.expect('idempotent: trg_validate_flock_sa survives re-run',
        EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.stock_adjustments'::regclass
                   AND tgname = 'trg_validate_flock_sa' AND NOT tgisinternal));
    PERFORM tests.expect('idempotent: all 5 require_farm_id triggers survive',
        (SELECT count(*) FROM pg_trigger
          WHERE tgname = 'trg_require_farm_id' AND NOT tgisinternal) = 5);
    RAISE NOTICE 'M5: all assertions passed.';
END;
$$;

ROLLBACK;