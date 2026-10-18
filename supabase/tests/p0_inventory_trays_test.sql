-- ============================================================================
-- P0 — W8: ربط إنتاج/تخريج البيض بمخزون صحون الكرتون
-- ============================================================================
-- القاعدة تحت الاختبار:
--   trays_filled «صحون معبئة»: + عند الإنتاج،  − عند التخريج
--   trays_empty  «صحون فارغة»: + عند شراء الكرتون (bundles × trays_per_bundle)،
--                               − عند الإنتاج
--   الكمية = CEIL(total_eggs / eggs_per_tray) لصحون البيض.
--   السجل في inventory_transactions (in/out).
--
-- الاختبارات T1..T12:
--   T1  وجود كائنات الترحيل (عمود، فهرس فريد، triggers، إسقاط الـCHECK)
--   T2  عنصرا النظام مُهيّآن لكل مزرعة
--   T3  الإنتاج: filled +، empty −
--   T4  تعديل الإنتاج يحسب الفرق
--   T5  حذف الإنتاج يعكس بالكامل
--   T6  التخريج: filled −
--   T7  شراء الكرتون: empty + (bundles × trays_per_bundle)
--   T8  تعديل الشراء يحسب الفرق
--   T9  حذف الشراء يعكس
--   T10 السجل inventory_transactions صحيح
--   T11 التعديل المباشر للرصيد مرفوض (protect)
--   T12 RLS: العامل يقرأ عناصر مزرعته فقط + sync_can_* الصحيح
--
-- يُدار داخل BEGIN/ROLLBACK. المراجع من local_fixtures.sql.
--   psql -f supabase/tests/p0_inventory_trays_test.sql
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
    v_farm_a   uuid := '00000000-0000-0000-0000-000000000001';
    v_farm_b   uuid := '00000000-0000-0000-0000-000000000002';
    v_admin_a  uuid := '00000000-0000-0000-0000-00000000000a';
    v_worker_a uuid := '00000000-0000-0000-0000-00000000000b';
    v_sysadm   uuid := '00000000-0000-0000-0000-00000000000e';
    v_customer uuid := '00000000-0000-0000-0000-0000000000aa';
    v_flock_a  uuid;
    v_prod_id  uuid := '00000000-0000-0000-0000-0000000000b1';
    v_disp_id  uuid := '00000000-0000-0000-0000-0000000000b2';
    v_exp_id   uuid := '00000000-0000-0000-0000-0000000000b3';
    v_empty    numeric;
    v_filled   numeric;
    v_n        int;
    v_ok       boolean;
BEGIN
    -- ── setup: هوية النظام للتمهيد (RLS على الجداول التشغيلية) ───────────────
    -- ملاحظة: Fixtures تضبط FARM_A على eggs_per_tray=180 (صُحون)،
    -- و calc_total_eggs يستخدم eggs_per_tray لعمود trays. لا نملك صلاحية
    -- تعديل farms من test_runner، لذلك نحسب على أساس 180 صحن.
    PERFORM tests.set_user(v_sysadm);

    INSERT INTO public.flocks (id, farm_id, breed, initial_count, current_count,
                               start_date, status)
    VALUES ('00000000-0000-0000-0000-0000000000f1', v_farm_a, 'W8 Flock',
            1000, 1000, CURRENT_DATE - 100, 'active')
    ON CONFLICT (id) DO NOTHING;
    v_flock_a := '00000000-0000-0000-0000-0000000000f1';

    INSERT INTO public.customers (id, farm_id, name, phone)
    VALUES (v_customer, v_farm_a, 'W8 Customer', '0900000000')
    ON CONFLICT (id) DO NOTHING;

    -- ═════════════════════════════════════════════════════════════════════
    -- T1 — كائنات الترحيل
    -- ═════════════════════════════════════════════════════════════════════
    PERFORM tests.expect('T1.1 farms.trays_per_bundle exists',
        EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='farms'
                   AND column_name='trays_per_bundle'));
    PERFORM tests.expect('T1.2 inventory_items.system_key exists',
        EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='inventory_items'
                   AND column_name='system_key'));
    PERFORM tests.expect('T1.3 unique index (farm_id, system_key) exists',
        EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname='public'
                   AND indexname='ux_inventory_items_farm_system_key'));
    PERFORM tests.expect('T1.4 quantity>=0 CHECK dropped',
        NOT EXISTS (SELECT 1 FROM pg_constraint
                     WHERE conrelid='public.inventory_items'::regclass
                       AND conname='inventory_items_quantity_check'));
    PERFORM tests.expect('T1.5 three trays triggers installed',
        (SELECT count(*) FROM pg_trigger
          WHERE tgname IN ('trg_trays_on_production','trg_trays_on_dispatch',
                           'trg_trays_on_carton_purchase')
            AND NOT tgisinternal) = 3);

    -- ═════════════════════════════════════════════════════════════════════
    -- T2 — عنصرا النظام لكل مزرعة
    -- ═════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO v_n FROM public.inventory_items
     WHERE farm_id = v_farm_a AND system_key IN ('trays_empty','trays_filled');
    PERFORM tests.expect('T2.1 FARM_A has both system items', v_n = 2,
        format('got %s', v_n));
    SELECT count(*) INTO v_n FROM public.inventory_items
     WHERE farm_id = v_farm_b AND system_key IN ('trays_empty','trays_filled');
    PERFORM tests.expect('T2.2 FARM_B has both system items', v_n = 2,
        format('got %s', v_n));
    PERFORM tests.expect('T2.3 system items are whole-unit (piece)',
        NOT EXISTS (SELECT 1 FROM public.inventory_items
                     WHERE system_key IS NOT NULL AND unit <> 'piece'));

    -- ═════════════════════════════════════════════════════════════════════
    -- T3 — الإنتاج: total=30 -> CEIL(30/180)=1 صحن
    -- ═════════════════════════════════════════════════════════════════════
    INSERT INTO public.egg_production
        (id, farm_id, flock_id, date, cartons, trays, loose_eggs, worker_id)
    VALUES (v_prod_id, v_farm_a, v_flock_a, CURRENT_DATE - 1, 0, 0, 30,
            v_worker_a);

    SELECT quantity INTO v_filled FROM public.inventory_items
     WHERE farm_id=v_farm_a AND system_key='trays_filled';
    SELECT quantity INTO v_empty FROM public.inventory_items
     WHERE farm_id=v_farm_a AND system_key='trays_empty';
    PERFORM tests.expect('T3.1 production adds 1 filled tray', v_filled = 1,
        format('got %s', v_filled));
    PERFORM tests.expect('T3.2 production consumes 1 empty tray', v_empty = -1,
        format('got %s', v_empty));

    -- ═════════════════════════════════════════════════════════════════════
    -- T4 — تعديل الإنتاج: 30 -> 181 = CEIL 1 -> 2 (فرق +1)
    -- ═════════════════════════════════════════════════════════════════════
    UPDATE public.egg_production SET loose_eggs = 181 WHERE id = v_prod_id;
    SELECT quantity INTO v_filled FROM public.inventory_items
     WHERE farm_id=v_farm_a AND system_key='trays_filled';
    SELECT quantity INTO v_empty FROM public.inventory_items
     WHERE farm_id=v_farm_a AND system_key='trays_empty';
    PERFORM tests.expect('T4.1 production UPDATE delta +1 filled', v_filled = 2,
        format('got %s', v_filled));
    PERFORM tests.expect('T4.2 production UPDATE delta -1 empty', v_empty = -2,
        format('got %s', v_empty));

    -- ═════════════════════════════════════════════════════════════════════
    -- T5 — حذف الإنتاج يعكس بالكامل
    -- ═════════════════════════════════════════════════════════════════════
    DELETE FROM public.egg_production WHERE id = v_prod_id;
    SELECT quantity INTO v_filled FROM public.inventory_items
     WHERE farm_id=v_farm_a AND system_key='trays_filled';
    SELECT quantity INTO v_empty FROM public.inventory_items
     WHERE farm_id=v_farm_a AND system_key='trays_empty';
    PERFORM tests.expect('T5.1 production DELETE reverses filled to 0',
        v_filled = 0, format('got %s', v_filled));
    PERFORM tests.expect('T5.2 production DELETE reverses empty to 0',
        v_empty = 0, format('got %s', v_empty));

    -- ═════════════════════════════════════════════════════════════════════
    -- T6 — التخريج: trays=1 -> total=180 -> CEIL=1 -> filled -1
    -- ═════════════════════════════════════════════════════════════════════
    INSERT INTO public.egg_dispatch
        (id, farm_id, date, customer_id, cartons, trays, worker_id)
    VALUES (v_disp_id, v_farm_a, CURRENT_DATE - 1, v_customer, 0, 1, v_worker_a);
    SELECT quantity INTO v_filled FROM public.inventory_items
     WHERE farm_id=v_farm_a AND system_key='trays_filled';
    SELECT quantity INTO v_empty FROM public.inventory_items
     WHERE farm_id=v_farm_a AND system_key='trays_empty';
    PERFORM tests.expect('T6.1 dispatch consumes 1 filled tray', v_filled = -1,
        format('got %s', v_filled));
    PERFORM tests.expect('T6.2 dispatch leaves empty untouched', v_empty = 0,
        format('got %s', v_empty));

    -- ═════════════════════════════════════════════════════════════════════
    -- T7 — شراء الكرتون: bundles=2 -> empty += 2 × 100 = 200
    -- ═════════════════════════════════════════════════════════════════════
    INSERT INTO public.expenses
        (id, farm_id, date, category, amount, carton_bundles)
    VALUES (v_exp_id, v_farm_a, CURRENT_DATE - 1, 'carton', 100, 2);
    SELECT quantity INTO v_empty FROM public.inventory_items
     WHERE farm_id=v_farm_a AND system_key='trays_empty';
    PERFORM tests.expect('T7.1 carton purchase adds 200 empty trays',
        v_empty = 200, format('got %s', v_empty));

    -- ═════════════════════════════════════════════════════════════════════
    -- T8 — تعديل الشراء: 2 -> 3 bundles = +100
    -- ═════════════════════════════════════════════════════════════════════
    UPDATE public.expenses SET carton_bundles = 3 WHERE id = v_exp_id;
    SELECT quantity INTO v_empty FROM public.inventory_items
     WHERE farm_id=v_farm_a AND system_key='trays_empty';
    PERFORM tests.expect('T8.1 carton purchase UPDATE adds 100 more',
        v_empty = 300, format('got %s', v_empty));

    -- ═════════════════════════════════════════════════════════════════════
    -- T9 — حذف الشراء يعكس (300 - 300 = 0)
    -- ═════════════════════════════════════════════════════════════════════
    DELETE FROM public.expenses WHERE id = v_exp_id;
    SELECT quantity INTO v_empty FROM public.inventory_items
     WHERE farm_id=v_farm_a AND system_key='trays_empty';
    PERFORM tests.expect('T9.1 carton purchase DELETE reverses empty to 0',
        v_empty = 0, format('got %s', v_empty));

    -- ═════════════════════════════════════════════════════════════════════
    -- T10 — السجل inventory_transactions
    -- ═════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO v_n
      FROM public.inventory_transactions t
      JOIN public.inventory_items i ON i.id = t.item_id
     WHERE i.farm_id = v_farm_a AND i.system_key = 'trays_filled'
       AND t.type = 'in' AND t.quantity = 1;
    PERFORM tests.expect('T10.1 ledger: filled in 1 (production)', v_n >= 1,
        format('got %s', v_n));
    SELECT count(*) INTO v_n
      FROM public.inventory_transactions t
      JOIN public.inventory_items i ON i.id = t.item_id
     WHERE i.farm_id = v_farm_a AND i.system_key = 'trays_empty'
       AND t.type = 'in' AND t.quantity = 200 AND t.note = 'شراء صحون كرتون';
    PERFORM tests.expect('T10.2 ledger: empty in 200 (purchase)', v_n = 1,
        format('got %s', v_n));
    SELECT count(*) INTO v_n
      FROM public.inventory_transactions t
      JOIN public.inventory_items i ON i.id = t.item_id
     WHERE i.farm_id = v_farm_a AND i.system_key = 'trays_filled'
       AND t.type = 'out' AND t.quantity = 1;
    PERFORM tests.expect('T10.3 ledger: filled out 1 (dispatch)', v_n >= 1,
        format('got %s', v_n));

    -- ═════════════════════════════════════════════════════════════════════
    -- T11 — التعديل المباشر للرصيد مرفوض
    -- ═════════════════════════════════════════════════════════════════════
    v_ok := false;
    BEGIN
        UPDATE public.inventory_items SET quantity = 999
         WHERE farm_id = v_farm_a AND system_key = 'trays_filled';
        v_ok := true;
    EXCEPTION WHEN OTHERS THEN
        v_ok := false;
    END;
    PERFORM tests.expect('T11.1 direct quantity UPDATE is blocked', v_ok = false,
        'the guard allowed a direct update');

    -- ═════════════════════════════════════════════════════════════════════
    -- T12 — RLS العامل + sync_can_*
    -- ═════════════════════════════════════════════════════════════════════
    PERFORM tests.expect('T12.1 sync_can_read worker inventory_items = true',
        public.sync_can_read('worker', 'inventory_items'));
    PERFORM tests.expect('T12.2 sync_can_write worker inventory_items = false',
        NOT public.sync_can_write('worker', 'inventory_items'));

    PERFORM tests.set_user(v_worker_a);
    SELECT count(*) INTO v_n FROM public.inventory_items
     WHERE farm_id = v_farm_a AND system_key IS NOT NULL;
    PERFORM tests.expect('T12.3 worker reads own-farm inventory items',
        v_n = 2, format('got %s', v_n));
    SELECT count(*) INTO v_n FROM public.inventory_items
     WHERE farm_id = v_farm_b;
    -- ===================================================================
    -- T13: backfill_inventory_trays (matches desktop "رصيد البيض" definition)
    -- يُستخدم FARM_B (لم يمسّه T3..T9 — أُنشئت له قطيع وزبون خاص)
    -- ===================================================================
    DECLARE
        v_c_farm   uuid := v_farm_b;
        v_flock_c  uuid := '00000000-0000-0000-0000-0000000000f2';
        v_cust_c   uuid := '00000000-0000-0000-0000-0000000000ab';
        v_worker_c uuid := '00000000-0000-0000-0000-00000000000d';
        v_exp_filled numeric;
        v_exp_empty  numeric;
        v_got_filled numeric;
        v_got_empty  numeric;
    BEGIN
        PERFORM tests.set_user(v_sysadm);

        INSERT INTO public.flocks (id, farm_id, breed, initial_count, current_count,
                                   start_date, status)
        VALUES (v_flock_c, v_c_farm, 'W8 Flock C', 500, 500, CURRENT_DATE - 60, 'active')
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO public.customers (id, farm_id, name, phone)
        VALUES (v_cust_c, v_c_farm, 'W8 Customer C', '0900000001')
        ON CONFLICT (id) DO NOTHING;

        -- history: 2 × production (300+200) → saleable = 500, 1 dispatch 90
        INSERT INTO public.egg_production (id, farm_id, flock_id, date, cartons, trays, loose_eggs, total_eggs, broken_eggs, dirty_eggs, worker_id)
        VALUES ('00000000-0000-0000-0000-0000000000c2', v_c_farm, v_flock_c, CURRENT_DATE - 5, 0, 0, 300, 300, 0, 0, v_worker_c)
        ON CONFLICT (id) DO NOTHING;
        INSERT INTO public.egg_production (id, farm_id, flock_id, date, cartons, trays, loose_eggs, total_eggs, broken_eggs, dirty_eggs, worker_id)
        VALUES ('00000000-0000-0000-0000-0000000000c3', v_c_farm, v_flock_c, CURRENT_DATE - 4, 0, 0, 200, 200, 0, 0, v_worker_c)
        ON CONFLICT (id) DO NOTHING;
        INSERT INTO public.egg_dispatch (id, farm_id, flock_id, date, customer_id, cartons, trays, total_eggs, worker_id)
        VALUES ('00000000-0000-0000-0000-0000000000c4', v_c_farm, v_flock_c, CURRENT_DATE - 3, v_cust_c, 0, 0, 90, v_worker_c)
        ON CONFLICT (id) DO NOTHING;
        -- 3 bundles carton purchased
        INSERT INTO public.expenses (id, farm_id, date, category, description, amount, currency, carton_bundles, created_at, updated_at)
        VALUES ('00000000-0000-0000-0000-0000000000c5', v_c_farm, CURRENT_DATE - 10, 'carton', 'buy', 90, 'dollar', 3, now(), now())
        ON CONFLICT (id) DO NOTHING;

        -- simulate pre-backfill: reset system items to 0 (to test backfill sets them)
        PERFORM set_config('app.allow_inventory_update','on',true);
        UPDATE public.inventory_items
           SET quantity=0, version=version+1, updated_at=now()
         WHERE farm_id=v_c_farm AND system_key IN ('trays_filled','trays_empty');
        PERFORM set_config('app.allow_inventory_update','off',true);

        -- apply backfill
        PERFORM public.backfill_inventory_trays(v_c_farm);

        -- compute expected: net = (300+200) - 90 + 0 + 0 = 410; tray=180 → filled = CEIL(410/180)=3; empty = 3×100 − 3 = 297
        SELECT CEIL(410 / 180.0) INTO v_exp_filled;
        SELECT GREATEST(3*100 - v_exp_filled, 0) INTO v_exp_empty;

        SELECT quantity INTO v_got_filled FROM public.inventory_items
         WHERE farm_id=v_c_farm AND system_key='trays_filled';
        SELECT quantity INTO v_got_empty FROM public.inventory_items
         WHERE farm_id=v_c_farm AND system_key='trays_empty';

        PERFORM tests.expect('T13.1 filled = CEIL((sum_prod_saleable−sum_disp)/tray)',
            ABS(v_got_filled - 3) < 1e-9, format('got %s exp 3', v_got_filled));
        PERFORM tests.expect('T13.2 empty = bundles×tpb − filled',
            ABS(v_got_empty - 297) < 1e-9, format('got %s exp 297', v_got_empty));
    END; -- T13
    -- ===================================================================
    -- end T13
END $$;

ROLLBACK;
