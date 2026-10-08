-- ============================================================================
-- P0 M3: medications.cost + currency + inventory_item_id
-- ============================================================================
-- The rules under test (docs/ACCOUNTING_RULES.md):
--   * cost >= 0 or NULL; currency in (dollar, lira), NOT NULL, default
--     'dollar'; inventory_item_id NULL-able, FK, ON DELETE SET NULL
--   * priority (app-level): inventory_item_id -> qty*unit_price, else
--     cost, else 0
--
-- Runs inside BEGIN/ROLLBACK. Fixtures from local_fixtures.sql
-- (FARM_A ...0001, admin_a ...000a). The old version of this file
-- INSERTed FARM_A (already a fixture -> duplicate key), omitted the
-- NOT NULL worker_id, and ran ALTER TABLE as test_runner; all three
-- made it unrunnable. This version is exercised by run_all suite 4f.
--   psql -f supabase/tests/p0_medications_cost_test.sql
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
    v_item    uuid;
    v_med     uuid;
    v_n       int;
    v_val     text;
BEGIN
    -- ── fixtures (no farms INSERT: FARM_A/FARM_B are fixtures already) ───
    PERFORM tests.set_user(v_sysadm);
    INSERT INTO public.flocks (farm_id, breed, initial_count, current_count,
                               start_date, status)
    VALUES (v_farm_b, 'M3 Flock B', 400, 400, CURRENT_DATE - 10, 'active');
    -- Read FARM_B's flock back while the identity can still see it. After the
    -- switch to manager A, flocks_read hides farm B, this SELECT would return
    -- NULL, and every cross-farm assertion below would silently turn into an
    -- assertion about NULL -- flock_id NULL passes the guard, so "rejected"
    -- would come back "accepted".
    SELECT id INTO v_flock_b FROM public.flocks
     WHERE farm_id = v_farm_b AND breed = 'M3 Flock B';

    PERFORM tests.set_user(v_admin_a);
    INSERT INTO public.flocks (farm_id, breed, initial_count, current_count,
                               start_date, status)
    VALUES (v_farm_a, 'M3 Flock A', 500, 500, CURRENT_DATE - 10, 'active');
    SELECT id INTO v_flock_a FROM public.flocks
     WHERE farm_id = v_farm_a AND breed = 'M3 Flock A';

    -- inventory_items carries no price column: the money for a medication
    -- lives in medications.cost (M3), and stock_adjustments.unit_price is
    -- what prices stock in. This row exists only to give inventory_item_id
    -- a valid FK target.
    INSERT INTO public.inventory_items (farm_id, name, quantity)
    VALUES (v_farm_a, 'M3 Test Item', 10)
    RETURNING id INTO v_item;

    -- ── 1. cost=100 accepted ─────────────────────────────────────────────
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, worker_id, cost, currency)
    VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'drug', 'Paracetamol', '500mg',
            'water', v_admin_a, 100.00, 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('cost=100 accepted', v_med IS NOT NULL);

    -- ── 2. cost=NULL accepted ────────────────────────────────────────────
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, worker_id, cost, currency)
    VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'vaccine', 'Vaccine A', '1ml',
            'injection', v_admin_a, NULL, 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('cost=NULL accepted', v_med IS NOT NULL);

    -- ── 3. cost=-1 rejected (CHECK) ──────────────────────────────────────
    BEGIN
        INSERT INTO public.medications
            (farm_id, flock_id, date, type, medicine_name, dosage,
             administration_route, worker_id, cost, currency)
        VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'drug', 'Bad', '10mg',
                'water', v_admin_a, -1.00, 'dollar');
        PERFORM tests.expect('cost=-1 rejected', false, 'accepted');
    EXCEPTION WHEN check_violation THEN
        PERFORM tests.expect('cost=-1 rejected', true);
    END;

    -- ── 4. inventory_item_id accepted ────────────────────────────────────
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, worker_id, inventory_item_id, currency)
    VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'drug', 'ItemMed', '10mg',
            'feed', v_admin_a, v_item, 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('inventory_item_id accepted', v_med IS NOT NULL);

    -- ── 5. cost + inventory_item_id together accepted ────────────────────
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, worker_id, cost, inventory_item_id, currency)
    VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'drug', 'BothMed', '10mg',
            'feed', v_admin_a, 50.00, v_item, 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('cost+inventory_item_id accepted', v_med IS NOT NULL);
    -- ── 6. currency='SAR' rejected (dollar/lira only) ────────────────────
    BEGIN
        INSERT INTO public.medications
            (farm_id, flock_id, date, type, medicine_name, dosage,
             administration_route, worker_id, currency)
        VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'drug', 'SARMed', '10mg',
                'water', v_admin_a, 'SAR');
        PERFORM tests.expect('currency SAR rejected', false, 'accepted');
    EXCEPTION WHEN check_violation THEN
        PERFORM tests.expect('currency SAR rejected', true);
    END;

    -- ── 7. invalid inventory_item_id rejected (FK) ───────────────────────
    BEGIN
        INSERT INTO public.medications
            (farm_id, flock_id, date, type, medicine_name, dosage,
             administration_route, worker_id, inventory_item_id, currency)
        VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'drug', 'BadItem', '10mg',
                'feed', v_admin_a,
                '00000000-0000-0000-0000-0000000000ff', 'dollar');
        PERFORM tests.expect('invalid inventory_item_id rejected',
            false, 'accepted');
    EXCEPTION WHEN foreign_key_violation THEN
        PERFORM tests.expect('invalid inventory_item_id rejected', true);
    END;

    -- ── 8. fallback row: cost NULL and no item (app charges 0) ───────────
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, worker_id)
    VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'vitamin', 'FreeVit', '1ml',
            'water', v_admin_a)
    RETURNING id INTO v_med;
    PERFORM tests.expect('fallback row (no cost, no item) accepted',
        v_med IS NOT NULL);

    -- ── 9. NUMERIC(19,4) precision accepted ──────────────────────────────
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, worker_id, cost, currency)
    VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'drug', 'Precise', '10mg',
            'water', v_admin_a, 12345678901234.5678, 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('cost precision 19,4 accepted', v_med IS NOT NULL);

    -- ── 10. currency 'yen' rejected ──────────────────────────────────────
    BEGIN
        INSERT INTO public.medications
            (farm_id, flock_id, date, type, medicine_name, dosage,
             administration_route, worker_id, currency)
        VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'drug', 'Yen', '10mg',
                'water', v_admin_a, 'yen');
        PERFORM tests.expect('currency yen rejected', false, 'accepted');
    EXCEPTION WHEN check_violation THEN
        PERFORM tests.expect('currency yen rejected', true);
    END;

    -- ── 11. cost=0 accepted (boundary) ───────────────────────────────────
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, worker_id, cost, currency)
    VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'drug', 'ZeroCost', '10mg',
            'water', v_admin_a, 0.00, 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('cost=0 accepted', v_med IS NOT NULL);

    -- ── 12. default currency = 'dollar' ──────────────────────────────────
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, worker_id)
    VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'drug', 'DefaultCurr', '10mg',
            'water', v_admin_a)
    RETURNING id INTO v_med;
    SELECT currency INTO v_val FROM public.medications WHERE id = v_med;
    PERFORM tests.expect('default currency is dollar', v_val = 'dollar');
    -- ── 13-15. column shapes ─────────────────────────────────────────────
    PERFORM tests.expect('cost is nullable',
        (SELECT is_nullable = 'YES' FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'medications'
            AND column_name = 'cost'));
    PERFORM tests.expect('currency is NOT NULL',
        (SELECT is_nullable = 'NO' FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'medications'
            AND column_name = 'currency'));
    PERFORM tests.expect('inventory_item_id is nullable',
        (SELECT is_nullable = 'YES' FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'medications'
            AND column_name = 'inventory_item_id'));

    -- ── 16. FK ON DELETE SET NULL ────────────────────────────────────────
    -- pg_constraint.confdeltype codes: a=NO ACTION, r=RESTRICT, c=CASCADE,
    -- n=SET NULL, d=SET DEFAULT. There is no 's'; asserting it here made
    -- the block fail even though the constraint was already correct.
    PERFORM tests.expect('FK is ON DELETE SET NULL',
        EXISTS (SELECT 1 FROM pg_constraint c
                 WHERE c.conname = 'medications_inventory_item_id_fkey'
                   AND c.conrelid = 'public.medications'::regclass
                   AND c.contype = 'f' AND c.confdeltype = 'n'));

    -- ── 17. row count: every accepted insert above persisted ─────────────
    SELECT count(*) INTO v_n FROM public.medications;
    PERFORM tests.expect('medications row count >= 7', v_n >= 7,
                         format('got %s', v_n));

    -- ── 18. another farm's flock rejected (cross-farm guard) ─────────────
    BEGIN
        INSERT INTO public.medications
            (farm_id, flock_id, date, type, medicine_name, dosage,
             administration_route, worker_id, cost, currency)
        VALUES (v_farm_a, v_flock_b, CURRENT_DATE, 'drug', 'Leak', '10mg',
                'water', v_admin_a, 10.00, 'dollar');
        PERFORM tests.expect('cross-farm flock rejected', false, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('cross-farm flock rejected',
            SQLERRM LIKE '%لا تنتمي%', SQLERRM);
    END;

    -- ── 19. worker_id missing rejected (NOT NULL) ────────────────────────
    BEGIN
        INSERT INTO public.medications
            (farm_id, flock_id, date, type, medicine_name, dosage,
             administration_route, currency)
        VALUES (v_farm_a, v_flock_a, CURRENT_DATE, 'drug', 'NoWorker', '10mg',
                'water', 'dollar');
        PERFORM tests.expect('missing worker_id rejected', false, 'accepted');
    EXCEPTION WHEN not_null_violation THEN
        PERFORM tests.expect('missing worker_id rejected', true);
    END;

    RAISE NOTICE 'M3 behavioural block passed';
END $$;

-- ── 20-21. idempotency: re-run M3's DDL exactly as the migration does ────
-- ALTER TABLE needs ownership; test_runner has none (same as M4/M5).
SET ROLE postgres;

ALTER TABLE medications
    ADD COLUMN IF NOT EXISTS cost NUMERIC(19,4)
        CHECK (cost IS NULL OR cost >= 0),
    ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT 'dollar'
        CHECK (currency IN ('dollar', 'lira')),
    ADD COLUMN IF NOT EXISTS inventory_item_id UUID;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'medications_inventory_item_id_fkey'
           AND conrelid = 'public.medications'::regclass
    ) THEN
        ALTER TABLE public.medications
            ADD CONSTRAINT medications_inventory_item_id_fkey
            FOREIGN KEY (inventory_item_id)
            REFERENCES public.inventory_items(id)
            ON DELETE SET NULL;
    END IF;
END;
$$;

DO $$
BEGIN
    PERFORM tests.expect('idempotent: cost column survives re-run',
        EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'medications'
                   AND column_name = 'cost'));
    PERFORM tests.expect('idempotent: FK survives re-run',
        EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'medications_inventory_item_id_fkey'
                   AND conrelid = 'public.medications'::regclass));
    RAISE NOTICE 'M3: all assertions passed.';
END;
$$;

ROLLBACK;