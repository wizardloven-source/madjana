-- ============================================================================
-- 20260926000400 - attach inventory items to a flock (per-flock equipment).
--
-- Why
-- ---
-- The app had no way to answer "what equipment does this flock have?".
-- `inventory_items` is farm-scoped (farm_id only); `equipment` existed solely
-- as a revenue category for selling gear, never as an entity.
--
-- Three parts:
--   1) the column + index,
--   2) a same-farm guard trigger,
--   3) sync_records_batch re-emitted so `flock_id` is in the allowlist.
--
-- Semantics
-- ---------
-- `flock_id` is a REFERENCE, not an allocation. The quantity stays farm-wide.
-- A given item row is assigned to AT MOST ONE flock: a shared item is one row
-- with `flock_id IS NULL`, shown under "shared" everywhere. So
-- SUM(quantity) over a flock's equipment is deliberately NOT farm stock and
-- must never be fed into stock maths.
--
-- Part 3 is why this file re-emits the whole function: the column allowlist is
-- a hardcoded CASE inside the function body, so there is no way to amend it
-- without CREATE OR REPLACE. The body below is copied verbatim from
-- 20260926000100 with exactly one change (inventory_items allowlist gains
-- 'flock_id'). If that migration is ever edited, this must be regenerated.
--
-- Idempotent. ASCII only.
-- ============================================================================

BEGIN;

-- 1) Column + index ---------------------------------------------------------
DO $$
BEGIN
    IF to_regclass('public.inventory_items') IS NULL THEN
        RAISE NOTICE 'inventory_items table missing; skipping';
        RETURN;
    END IF;

    -- flocks is the table actually referenced by the FK, so it is the one that
    -- must be probed. Checking farms instead would let this ALTER run and then
    -- fail on a deployment that has no flocks table.
    IF to_regclass('public.flocks') IS NULL THEN
        RAISE NOTICE 'flocks table missing; skipping inventory_items.flock_id';
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                     AND table_name   = 'inventory_items'
                     AND column_name  = 'flock_id') THEN
        -- ON DELETE SET NULL: deleting a flock must not delete the gear, it
        -- should just un-assign it. The guard trigger below then stops
        -- inventory_items from outliving its own farm row.
        EXECUTE 'ALTER TABLE public.inventory_items
                 ADD COLUMN flock_id UUID REFERENCES public.flocks(id) ON DELETE SET NULL';
        RAISE NOTICE 'added inventory_items.flock_id';
    END IF;
END;
$$;

DO $$
BEGIN
    IF to_regclass('public.inventory_items') IS NOT NULL THEN
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_inventory_items_flock_id
                 ON public.inventory_items(flock_id)';
    END IF;
END;
$$;

-- 2) Same-farm guard --------------------------------------------------------
-- A FK on flock_id proves the flock exists, not that it belongs to the same
-- farm as the item. Without this, a manager of farm A could point an item at
-- farm B's flock and leak that flock's name into A's equipment list.
CREATE OR REPLACE FUNCTION public.inventory_items_flock_same_farm()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_farm uuid;
BEGIN
    IF NEW.flock_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT f.farm_id INTO v_farm
    FROM public.flocks f
    WHERE f.id = NEW.flock_id;

    -- No row: the flock was deleted between the write and this trigger, or the
    -- caller bypassed the FK. Either way, do not accept a dangling reference.
    IF v_farm IS NULL THEN
        RAISE EXCEPTION 'flock % does not exist', NEW.flock_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF v_farm <> NEW.farm_id THEN
        RAISE EXCEPTION 'flock % belongs to a different farm than the item',
            NEW.flock_id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

DO $$
BEGIN
    IF to_regclass('public.inventory_items') IS NOT NULL THEN
        DROP TRIGGER IF EXISTS trg_inventory_items_flock_same_farm
            ON public.inventory_items;
        CREATE TRIGGER trg_inventory_items_flock_same_farm
            BEFORE INSERT OR UPDATE OF flock_id, farm_id
            ON public.inventory_items
            FOR EACH ROW EXECUTE FUNCTION public.inventory_items_flock_same_farm();
    END IF;
END;
$$;

-- 3) sync_records_batch re-emit (flock_id added to the allowlist) -----------
CREATE OR REPLACE FUNCTION public.sync_records_batch(p_records jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rec            jsonb;
    v_record_id      uuid;
    v_table_name     text;
    v_operation      text;
    v_data           jsonb;
    v_user_farm      uuid;
    v_user_role      text;
    v_operation_id   text;
    v_device         text;
    v_affected       int := 0;
    v_skipped        int := 0;
    v_errors         int := 0;
    v_result         jsonb := '[]'::jsonb;
    v_new_version    bigint;
    v_prev_version   bigint;
    v_allowed_cols   text[];
    v_cols           text[];
    v_vals           text[];
    v_set_parts      text[];
    v_col            text;
    v_existing       record;
    v_existing_ver   bigint;
    v_inserted       int;
    v_upd_count      int;
    v_del_count      int;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: not signed in';
    END IF;

    v_user_farm := current_user_farm_id();
    v_user_role := current_user_role();

    IF v_user_farm IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: no farm bound to this user';
    END IF;

    FOR v_rec IN SELECT * FROM jsonb_array_elements(p_records) LOOP
        v_record_id    := NULLIF(v_rec->>'record_id', '')::uuid;
        v_table_name   := v_rec->>'table_name';
        v_operation    := upper(v_rec->>'operation');
        v_data         := COALESCE(v_rec->'data', '{}'::jsonb);
        v_operation_id := NULLIF(v_rec->>'operation_id', '');
        v_device       := NULLIF(v_rec->>'device_id', '');
        v_prev_version := NULLIF(v_rec->>'previous_version', '')::bigint;

        IF v_record_id IS NULL OR v_table_name IS NULL
           OR v_operation NOT IN ('INSERT','UPDATE','DELETE') THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', COALESCE(v_rec->>'record_id', ''),
                'table_name', COALESCE(v_table_name, ''),
                'operation_id', v_operation_id,
                'status', 'error',
                'message', 'invalid record shape'
            );
            CONTINUE;
        END IF;

        IF NOT public.sync_can_write(v_user_role, v_table_name) THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'error',
                'message', 'AUTHORIZATION_DENIED: role may not write ' || v_table_name
            );
            CONTINUE;
        END IF;

        CASE v_table_name
            WHEN 'flocks' THEN v_allowed_cols := ARRAY['breed','start_date','initial_count','current_count','status','sections_count'];
            WHEN 'egg_production' THEN v_allowed_cols := ARRAY['flock_id','date','eggs_collected','eggs_sold','eggs_broken','notes'];
            WHEN 'mortality' THEN v_allowed_cols := ARRAY['flock_id','date','count','cause','notes'];
            WHEN 'feed_consumption' THEN v_allowed_cols := ARRAY['flock_id','date','quantity_kg','feed_type','supplier_id','cost','notes'];
            WHEN 'feed_received' THEN v_allowed_cols := ARRAY['supplier_id','date','quantity_bags','price_per_kg','total_cost','notes'];
            WHEN 'egg_dispatch' THEN v_allowed_cols := ARRAY['flock_id','customer_id','date','cartons','trays','total_eggs','unit_price','payment_status','notes','worker_id'];
            WHEN 'medications' THEN v_allowed_cols := ARRAY['flock_id','date','type','medicine_name','dosage','administration_route','treatment_days','withdrawal_days','notes','worker_id'];
            WHEN 'expenses' THEN v_allowed_cols := ARRAY['date','category','description','amount','currency','exchange_rate','carton_bundles'];
            WHEN 'inventory_items' THEN v_allowed_cols := ARRAY['name','unit','low_stock_threshold','notes','flock_id'];
            WHEN 'inventory_transactions' THEN v_allowed_cols := ARRAY['item_id','date','type','quantity','note','user_id'];
            WHEN 'opening_balances' THEN v_allowed_cols := ARRAY['flock_id','date','eggs','feed_kg'];
            WHEN 'payments' THEN v_allowed_cols := ARRAY['dispatch_id','date','amount','method','notes'];
            WHEN 'revenue' THEN v_allowed_cols := ARRAY['date','category','description','amount','currency','exchange_rate','quantity','unit','reference_id','worker_id'];
            WHEN 'stock_adjustments' THEN v_allowed_cols := ARRAY['item_id','date','type','quantity','reason','notes'];
            WHEN 'dispatch_requests'
                -- The worker creates the request, so it must be allowed to
                -- broadcast. status / decided_* stay manager-only: approving a
                -- dispatch is a manager decision, not a worker one.
                THEN v_allowed_cols := CASE
                    WHEN v_user_role = 'manager'
                        THEN ARRAY['cartons','trays','total_eggs','flock_id',
                                    'stock_eggs','status','worker_id']
                    ELSE ARRAY['cartons','trays','total_eggs','flock_id']
                END;
            -- customers: is_global is excluded on purpose. The scope guard is
            -- BEFORE INSERT only, so allowing it on UPDATE would let a worker
            -- promote a customer to global visibility across every farm.
            WHEN 'customers' THEN v_allowed_cols := ARRAY['name','phone','notes'];
            ELSE v_allowed_cols := ARRAY[]::text[];
        END CASE;

        -- Workers must not write financial columns, and must not touch flocks
        -- or customers at all. dispatch_requests is deliberately excluded
        -- from this wipe: the worker is required to create it.
        IF v_user_role <> 'manager' THEN
            IF v_table_name = 'feed_received' THEN
                v_allowed_cols := array_remove(v_allowed_cols, 'price_per_kg');
            ELSIF v_table_name = 'egg_dispatch' THEN
                v_allowed_cols := array_remove(v_allowed_cols, 'payment_status');
            ELSIF v_table_name IN ('flocks', 'customers') THEN
                v_allowed_cols := ARRAY[]::text[];
            END IF;
            IF v_user_role = 'worker' THEN
                v_allowed_cols := array_remove(v_allowed_cols, 'worker_id');
            END IF;
        END IF;

        -- Hard delete is manager-only.
        IF v_operation = 'DELETE' AND v_user_role <> 'manager' THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'error',
                'message', 'AUTHORIZATION_DENIED: delete is manager only'
            );
            CONTINUE;
        END IF;

        BEGIN
            IF v_operation = 'INSERT' THEN
                -- FIX (a): a pre-existing row used to be reported 'ok' and then
                -- CONTINUE, which skipped the broadcast below. Upsert instead.
                EXECUTE format(
                    'SELECT * FROM %I WHERE id = $1 AND farm_id = $2',
                    v_table_name
                ) INTO v_existing USING v_record_id, v_user_farm;

                v_cols := ARRAY['id','farm_id','version'];
                v_vals := ARRAY[
                    quote_literal(v_record_id::text),
                    quote_literal(v_user_farm::text),
                    '1'
                ];
                FOR v_col IN SELECT jsonb_object_keys(v_data) LOOP
                    IF v_col = ANY(v_allowed_cols) THEN
                        v_cols := array_append(v_cols, v_col);
                        v_vals := array_append(v_vals, quote_nullable(v_data->>v_col));
                    END IF;
                END LOOP;

                IF FOUND THEN
                    v_existing_ver := COALESCE((v_existing).version, 1);

                    v_set_parts := ARRAY[]::text[];
                    FOR v_col IN SELECT jsonb_object_keys(v_data) LOOP
                        IF v_col = ANY(v_allowed_cols) THEN
                            v_set_parts := array_append(v_set_parts,
                                format('%I = %s', v_col, quote_nullable(v_data->>v_col)));
                        END IF;
                    END LOOP;

                    IF array_length(v_set_parts, 1) IS NULL THEN
                        v_skipped := v_skipped + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id,
                            'table_name', v_table_name,
                            'operation_id', v_operation_id,
                            'status', 'skipped',
                            'message', 'no writable columns in payload'
                        );
                        CONTINUE;
                    END IF;

                    EXECUTE format(
                        'UPDATE %I SET %s, version = version + 1, updated_at = NOW()
                         WHERE id = %s AND farm_id = %s',
                        v_table_name,
                        array_to_string(v_set_parts, ', '),
                        quote_nullable(v_record_id::text),
                        quote_nullable(v_user_farm::text)
                    );
                    GET DIAGNOSTICS v_upd_count = ROW_COUNT;

                    IF v_upd_count = 0 THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id,
                            'table_name', v_table_name,
                            'operation_id', v_operation_id,
                            'status', 'error',
                            'message', 'update affected no rows'
                        );
                        CONTINUE;
                    END IF;

                    v_affected := v_affected + 1;
                    v_new_version := v_existing_ver + 1;
                ELSE
                    EXECUTE format(
                        'INSERT INTO %I (%s) VALUES (%s)',
                        v_table_name,
                        array_to_string(v_cols, ', '),
                        array_to_string(v_vals, ', ')
                    );
                    GET DIAGNOSTICS v_inserted = ROW_COUNT;
                    v_affected := v_affected + 1;
                    v_new_version := 1;
                END IF;

            ELSIF v_operation = 'UPDATE' THEN
                v_set_parts := ARRAY[]::text[];
                FOR v_col IN SELECT jsonb_object_keys(v_data) LOOP
                    IF v_col = ANY(v_allowed_cols) THEN
                        v_set_parts := array_append(v_set_parts,
                            format('%I = %s', v_col, quote_nullable(v_data->>v_col)));
                    END IF;
                END LOOP;

                IF array_length(v_set_parts, 1) IS NULL THEN
                    v_skipped := v_skipped + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id,
                        'table_name', v_table_name,
                        'operation_id', v_operation_id,
                        'status', 'skipped',
                        'message', 'no writable columns in update'
                    );
                    CONTINUE;
                END IF;

                -- FIX (b): OCC only applies when the client told us which
                -- version it expected. A NULL previous_version previously
                -- matched nothing, so the op always came back as a conflict.
                IF v_prev_version IS NULL THEN
                    EXECUTE format(
                        'UPDATE %I SET %s, version = version + 1, updated_at = NOW()
                         WHERE id = %s AND farm_id = %s',
                        v_table_name,
                        array_to_string(v_set_parts, ', '),
                        quote_nullable(v_record_id::text),
                        quote_nullable(v_user_farm::text)
                    );
                ELSE
                    EXECUTE format(
                        'UPDATE %I SET %s, version = version + 1, updated_at = NOW()
                         WHERE id = %s AND farm_id = %s AND version = %s',
                        v_table_name,
                        array_to_string(v_set_parts, ', '),
                        quote_nullable(v_record_id::text),
                        quote_nullable(v_user_farm::text),
                        v_prev_version
                    );
                END IF;

                GET DIAGNOSTICS v_upd_count = ROW_COUNT;
                IF v_upd_count = 0 THEN
                    v_errors := v_errors + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id,
                        'table_name', v_table_name,
                        'operation_id', v_operation_id,
                        'status', 'conflict',
                        'message', 'version conflict on update'
                    );
                    CONTINUE;
                END IF;

                v_affected := v_affected + 1;
                v_new_version := COALESCE(v_prev_version, 0) + 1;

            ELSE
                EXECUTE format(
                    'UPDATE %I SET deleted_at = NOW(), version = version + 1
                     WHERE id = %s AND farm_id = %s',
                    v_table_name,
                    quote_nullable(v_record_id::text),
                    quote_nullable(v_user_farm::text)
                );
                GET DIAGNOSTICS v_del_count = ROW_COUNT;

                IF v_del_count = 0 THEN
                    v_skipped := v_skipped + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id,
                        'table_name', v_table_name,
                        'operation_id', v_operation_id,
                        'status', 'skipped',
                        'message', 'row not found on server'
                    );
                    CONTINUE;
                END IF;

                v_affected := v_affected + 1;
                v_new_version := 1;
            END IF;

            SELECT version INTO v_new_version
            FROM sync_changes
            WHERE table_name = v_table_name
              AND record_id = v_record_id
            ORDER BY server_version DESC
            LIMIT 1;

            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'ok',
                'new_version', COALESCE(v_new_version, 1)
            );

            IF v_operation_id IS NOT NULL AND length(v_operation_id) > 0 THEN
                INSERT INTO idempotency_log
                    (operation_id, user_id, farm_id, table_name, record_id, operation, status, result)
                VALUES
                    (v_operation_id, auth.uid(), v_user_farm, v_table_name,
                     v_record_id, v_operation, 'done',
                     jsonb_build_object('new_version', COALESCE(v_new_version, 1)))
                ON CONFLICT (operation_id) DO NOTHING;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', COALESCE(v_rec->>'record_id', ''),
                'table_name', COALESCE(v_table_name, ''),
                'operation_id', v_operation_id,
                'status', 'error',
                'message', SQLERRM
            );
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'affected', v_affected,
        'skipped',  v_skipped,
        'errors',   v_errors,
        'details',  v_result
    );
END;
$$;

COMMIT;
