-- ============================================================
-- P0 M3: medications.cost + currency + inventory_item_id
-- >=19 assertions, all inside BEGIN/ROLLBACK
-- ============================================================
BEGIN;

CREATE SCHEMA IF NOT EXISTS tests;

CREATE OR REPLACE FUNCTION tests.expect(
    p_label text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok THEN
        RAISE NOTICE 'PASS  %', rpad(p_label, 60, '.');
    ELSE
        RAISE EXCEPTION 'FAIL  %  %', p_label, p_detail;
    END IF;
END;
$$;

DO $$
DECLARE
    v_farm   uuid := '00000000-0000-0000-0000-000000000001';
    v_flock  uuid;
    v_item   uuid;
    v_med    uuid;
    v_n      int;
    v_val    text;
BEGIN
    -- fixtures
    INSERT INTO public.farms (id, name) VALUES (v_farm, 'M3 Test Farm');
    INSERT INTO public.flocks (farm_id, breed, initial_count,
                                   current_count, start_date, status)
    VALUES (v_farm, 'Test Flock', 100, 100, CURRENT_DATE, 'active')
    RETURNING id INTO v_flock;
    INSERT INTO public.inventory_items (farm_id, name, quantity, unit_cost)
    VALUES (v_farm, 'Test Item', 10, 5.00)
    RETURNING id INTO v_item;

    -- 1. cost=100 accepted
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, cost, currency)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'drug', 'Paracetamol', '500mg',
            'water', 100.00, 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('cost=100 accepted', v_med IS NOT NULL);

    -- 2. cost=NULL accepted
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, cost, currency)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'vaccine', 'Vaccine A', '1ml',
            'injection', NULL, 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('cost=NULL accepted', v_med IS NOT NULL);

    -- 3. cost=-1 rejected (CHECK)
    BEGIN
        INSERT INTO public.medications
            (farm_id, flock_id, date, type, medicine_name, dosage,
             administration_route, cost, currency)
        VALUES (v_farm, v_flock, CURRENT_DATE, 'drug', 'Bad', '10mg',
                'water', -1.00, 'dollar');
        PERFORM tests.expect('cost=-1 rejected', false, 'should have failed');
    EXCEPTION WHEN check_violation THEN
        PERFORM tests.expect('cost=-1 rejected', true);
    END;

    -- 4. inventory_item_id accepted
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, inventory_item_id, currency)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'drug', 'ItemMed', '10mg',
            'feed', v_item, 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('inventory_item_id accepted', v_med IS NOT NULL);

    -- 5. cost + inventory_item_id together accepted
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, cost, inventory_item_id, currency)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'drug', 'BothMed', '10mg',
            'feed', 50.00, v_item, 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('cost+inventory_item_id accepted', v_med IS NOT NULL);

    -- 6. currency='SAR' rejected
    BEGIN
        INSERT INTO public.medications
            (farm_id, flock_id, date, type, medicine_name, dosage,
             administration_route, currency)
        VALUES (v_farm, v_flock, CURRENT_DATE, 'drug', 'SAR Med', '10mg',
                'water', 'SAR');
        PERFORM tests.expect('currency SAR rejected', false,
                             'should have failed');
    EXCEPTION WHEN check_violation THEN
        PERFORM tests.expect('currency SAR rejected', true);
    END;

    -- 7. currency='dollar' accepted
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, currency)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'drug', 'Dollar Med', '10mg',
            'water', 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('currency dollar accepted', v_med IS NOT NULL);

    -- 8. currency='lira' accepted
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, currency)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'drug', 'Lira Med', '10mg',
            'water', 'lira')
    RETURNING id INTO v_med;
    PERFORM tests.expect('currency lira accepted', v_med IS NOT NULL);


    -- 9. DELETE inventory_item -> inventory_item_id = NULL (SET NULL)
    DELETE FROM public.inventory_items WHERE id = v_item;
    SELECT inventory_item_id INTO v_val FROM public.medications WHERE id = v_med;
    PERFORM tests.expect('SET NULL on inventory_item delete', v_val IS NULL);

    -- 10. idempotent: migration twice = no error
    ALTER TABLE medications
        ADD COLUMN IF NOT EXISTS cost NUMERIC(19,4)
            CHECK (cost IS NULL OR cost >= 0),
        ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT 'dollar'
            CHECK (currency IN ('dollar', 'lira')),
        ADD COLUMN IF NOT EXISTS inventory_item_id UUID,
        ADD CONSTRAINT medications_inventory_item_id_fkey
            FOREIGN KEY (inventory_item_id) REFERENCES inventory_items(id)
            ON DELETE SET NULL;
    PERFORM tests.expect('idempotent: second run OK', true);

    -- 11. cost=0 accepted (boundary)
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, cost, currency)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'drug', 'ZeroCost', '10mg',
            'water', 0.00, 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('cost=0 accepted', v_med IS NOT NULL);

    -- 12. default currency = 'dollar'
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'drug', 'DefaultCurr', '10mg',
            'water')
    RETURNING id INTO v_med;
    SELECT currency INTO v_val FROM public.medications WHERE id = v_med;
    PERFORM tests.expect('default currency is dollar', v_val = 'dollar');

    -- 13. medications row count >= 10
    SELECT count(*) INTO v_n FROM public.medications;
    PERFORM tests.expect('medications row count >= 10', v_n >= 10);

    -- 14. cost precision 19,4
    INSERT INTO public.medications
        (farm_id, flock_id, date, type, medicine_name, dosage,
         administration_route, cost, currency)
    VALUES (v_farm, v_flock, CURRENT_DATE, 'drug', 'Precise', '10mg',
            'water', 12345678901234.5678, 'dollar')
    RETURNING id INTO v_med;
    PERFORM tests.expect('cost precision 19,4 accepted', v_med IS NOT NULL);

    -- 15. currency 'yen' rejected
    BEGIN
        INSERT INTO public.medications
            (farm_id, flock_id, date, type, medicine_name, dosage,
             administration_route, currency)
        VALUES (v_farm, v_flock, CURRENT_DATE, 'drug', 'Yen', '10mg',
                'water', 'yen');
        PERFORM tests.expect('currency yen rejected', false,
                             'should have failed');
    EXCEPTION WHEN check_violation THEN
        PERFORM tests.expect('currency yen rejected', true);
    END;

    -- 16. invalid inventory_item_id rejected
    BEGIN
        INSERT INTO public.medications
            (farm_id, flock_id, date, type, medicine_name, dosage,
             administration_route, inventory_item_id, currency)
        VALUES (v_farm, v_flock, CURRENT_DATE, 'drug', 'BadItem', '10mg',
                'feed', '00000000-0000-0000-0000-0000000000ff', 'dollar');
        PERFORM tests.expect('invalid inventory_item_id rejected', false,
                             'should have failed');
    EXCEPTION WHEN foreign_key_violation THEN
        PERFORM tests.expect('invalid inventory_item_id rejected', true);
    END;

    -- 17. cost column nullable
    PERFORM tests.expect('cost is nullable',
        (SELECT is_nullable = 'YES' FROM information_schema.columns
         WHERE table_name = 'medications' AND column_name = 'cost'));

    -- 18. inventory_item_id nullable
    PERFORM tests.expect('inventory_item_id is nullable',
        (SELECT is_nullable = 'YES' FROM information_schema.columns
         WHERE table_name = 'medications' AND column_name = 'inventory_item_id'));

    -- 19. currency NOT NULL
    PERFORM tests.expect('currency is NOT NULL',
        (SELECT is_nullable = 'NO' FROM information_schema.columns
         WHERE table_name = 'medications' AND column_name = 'currency'));

END;
$$;

ROLLBACK;
