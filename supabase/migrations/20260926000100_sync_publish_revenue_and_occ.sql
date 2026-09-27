-- ============================================================================
-- 20260926000100 - repair revenue publication + prevent silent data loss
-- Target: Supabase / Postgres. Single transaction. Idempotent.
-- Apply via SQL Editor (project has no numbered migration lineage).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1) Attach trg_populate_sync to revenue.
--    revenue had no trigger at all, so no sync_changes row was ever produced
--    and no device could ever receive a revenue change.
-- ----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_populate_sync ON revenue;
CREATE TRIGGER trg_populate_sync
    AFTER INSERT OR UPDATE OR DELETE ON revenue
    FOR EACH ROW EXECUTE FUNCTION public.populate_sync_changes();

-- revenue is missing columns that sync_records_batch touches.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                     AND table_name = 'revenue'
                     AND column_name = 'deleted_at') THEN
        ALTER TABLE revenue ADD COLUMN deleted_at TIMESTAMPTZ;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                     AND table_name = 'revenue'
                     AND column_name = 'version') THEN
        ALTER TABLE revenue ADD COLUMN version BIGINT NOT NULL DEFAULT 1;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                     AND table_name = 'revenue'
                     AND column_name = 'sync_status') THEN
        ALTER TABLE revenue ADD COLUMN sync_status TEXT DEFAULT 'synced';
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_revenue_deleted_at ON revenue (farm_id, deleted_at);

-- dispatch_requests: it is referenced by the sync allow lists below, but the
-- table lacks deleted_at / version. The dynamic filter queries
-- "WHERE ... AND deleted_at IS NULL"; without the column every pull raises an
-- exception, so dispatch requests stay invisible on every device.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                     AND table_name = 'dispatch_requests'
                     AND column_name = 'deleted_at') THEN
        ALTER TABLE dispatch_requests ADD COLUMN deleted_at TIMESTAMPTZ;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                     AND table_name = 'dispatch_requests'
                     AND column_name = 'version') THEN
        ALTER TABLE dispatch_requests ADD COLUMN version BIGINT NOT NULL DEFAULT 1;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_dispatch_requests_deleted_at
    ON dispatch_requests (farm_id, deleted_at);

-- ----------------------------------------------------------------------------
-- 2) sync_live_exists: add revenue + dispatch_requests.
--    Without revenue here, pull_remote_changes filters every revenue change out
--    even after the trigger starts writing rows.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_live_exists(p_table text, p_id uuid, p_farm uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result boolean;
BEGIN
    IF p_table NOT IN (
        'flocks','egg_production','mortality','feed_consumption','feed_received',
        'egg_dispatch','medications','customers','expenses','inventory_items',
        'inventory_transactions','opening_balances','payments','revenue',
        'stock_adjustments','dispatch_requests'
    ) THEN
        RETURN false;
    END IF;

    -- These two carry no farm_id/deleted_at in every deployment, so the probe
    -- raises. Return true explicitly (fail-open) rather than silently swallow.
    IF p_table IN ('inventory_transactions', 'opening_balances') THEN
        RETURN true;
    END IF;

    BEGIN
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM %I WHERE id = $1 AND farm_id = $2 AND deleted_at IS NULL)',
            p_table
        ) INTO v_result USING p_id, p_farm;
        RETURN v_result;
    EXCEPTION WHEN OTHERS THEN
        RETURN true;
    END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_live_exists(text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_live_exists(text, uuid, uuid) TO service_role;

-- ----------------------------------------------------------------------------
-- 3) sync_live_ids: add revenue + dispatch_requests, and report probe failures
--    instead of dropping the table from the result without a trace.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_live_ids(p_farm_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role   text;
    v_tables text[] := '{}'::text[];
    v_t      text;
    v_ids    jsonb;
    v_result jsonb := '{}'::jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: not signed in';
    END IF;

    v_role := current_user_role();
    IF NOT is_system_admin() AND current_user_farm_id() IS DISTINCT FROM p_farm_id THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: foreign farm';
    END IF;

    IF is_system_admin() OR v_role = 'manager' THEN
        v_tables := ARRAY['flocks','egg_production','mortality','feed_consumption',
                          'feed_received','egg_dispatch','medications','customers',
                          'expenses','inventory_items',
                          'payments','revenue','stock_adjustments',
                          'dispatch_requests'];
    ELSIF v_role = 'worker' THEN
        v_tables := ARRAY['egg_production','mortality','feed_consumption',
                          'feed_received','egg_dispatch','medications','revenue',
                          'dispatch_requests'];
    ELSE
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: role not allowed';
    END IF;

    FOREACH v_t IN ARRAY v_tables LOOP
        IF NOT public.sync_can_read(v_role, v_t) THEN
            CONTINUE;
        END IF;
        BEGIN
            EXECUTE format(
                'SELECT COALESCE(jsonb_agg(id), ''[]''::jsonb) FROM %I WHERE farm_id = $1 AND deleted_at IS NULL',
                v_t
            ) INTO v_ids USING p_farm_id;
            v_result := v_result || jsonb_build_object(v_t, v_ids);
        EXCEPTION WHEN OTHERS THEN
            v_result := v_result || jsonb_build_object(
                v_t, '[]'::jsonb,
                '_warning', SQLERRM
            );
        END;
    END LOOP;

    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_live_ids(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_live_ids(uuid) TO service_role;

-- ----------------------------------------------------------------------------
-- 4) sync_can_write / sync_can_read.
--    worker gains dispatch_requests: the worker is the actor that creates the
--    request, and it was rejected outright before.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_can_write(p_role text, p_table text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT
        CASE p_role
            WHEN 'worker' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications', 'revenue',
                'dispatch_requests'
            )
            WHEN 'manager' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications',
                'customers', 'flocks', 'expenses', 'payments',
                'inventory_items', 'inventory_transactions',
                'opening_balances', 'revenue', 'stock_adjustments',
                'dispatch_requests'
            )
            WHEN 'system_admin' THEN p_table NOT IN ('users', 'farms')
            ELSE false
        END;
$$;

CREATE OR REPLACE FUNCTION public.sync_can_read(p_role text, p_table text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT
        CASE p_role
            WHEN 'worker' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications', 'revenue',
                'dispatch_requests'
            )
            WHEN 'manager' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications',
                'customers', 'flocks', 'expenses', 'payments',
                'inventory_items', 'inventory_transactions',
                'opening_balances', 'revenue', 'stock_adjustments',
                'dispatch_requests'
            )
            WHEN 'system_admin' THEN p_table NOT IN ('users', 'farms')
            ELSE false
        END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_can_write(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_can_write(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.sync_can_read(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_can_read(text, text) TO service_role;

-- ----------------------------------------------------------------------------
-- 5) sync_records_batch.
--    Fixes:
--      a) INSERT onto a row that already exists used to be reported 'ok' and
--         then CONTINUE, skipping the sync_changes broadcast entirely. An
--         offline flock edit would be announced as synced and never sent.
--      b) UPDATE/DELETE matched on version = previous_version. A NULL
--         previous_version matched nothing, so every such op failed forever.
--      c) dispatch_requests was emptied for non-managers, so every worker
--         request resolved to 'skipped'.
--      d) is_global on customers: trg_customers_scope_guard is BEFORE INSERT
--         only, so an UPDATE bypasses it and a worker could promote a customer
--         to global visibility across every farm. Excluded on purpose.
--      e) details carries operation_id so the client can match by it.
-- ----------------------------------------------------------------------------
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
            WHEN 'inventory_items' THEN v_allowed_cols := ARRAY['name','unit','low_stock_threshold','notes'];
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

GRANT EXECUTE ON FUNCTION public.sync_records_batch(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_records_batch(jsonb) TO service_role;

-- ----------------------------------------------------------------------------
-- 6) pull_remote_changes.
--    Same signature and same jsonb contract the client already calls:
--      rpc('pull_remote_changes', {p_farm_id, p_from_version})
--    Two fixes inside:
--      a) the manager/system_admin branch had no sync_can_read filter at all,
--         so any table present in sync_changes was pulled regardless of role.
--      b) a worker computed the watermark across all tables, including tables
--         it may not read, which advanced its checkpoint past changes it can
--         never see.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pull_remote_changes(
    p_farm_id uuid,
    p_from_version bigint DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role            text;
    v_latest          bigint;
    v_min_keep        bigint;
    v_changes         jsonb;
    v_operational_only boolean := false;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: not signed in';
    END IF;

    IF NOT public.is_system_admin() THEN
        SELECT public.current_user_role() INTO v_role;
        IF v_role NOT IN ('manager', 'worker') THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: role not allowed to pull';
        END IF;
        IF p_farm_id IS DISTINCT FROM public.current_user_farm_id() THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: foreign farm';
        END IF;
        IF v_role = 'worker' THEN
            v_operational_only := true;
        END IF;
    END IF;

    SELECT latest_version, purged_below INTO v_latest, v_min_keep
    FROM sync_checkpoint WHERE farm_id = p_farm_id;

    IF v_latest IS NULL THEN
        SELECT COALESCE(MAX(server_version), 0), COALESCE(MIN(server_version), 0)
            INTO v_latest, v_min_keep
        FROM sync_changes WHERE farm_id = p_farm_id;
        IF v_min_keep = 0 THEN
            v_min_keep := v_latest;
        END IF;
        INSERT INTO sync_checkpoint (farm_id, latest_version, purged_below, updated_at)
        VALUES (p_farm_id, v_latest, v_min_keep, NOW())
        ON CONFLICT (farm_id) DO UPDATE SET
            latest_version = EXCLUDED.latest_version,
            purged_below   = EXCLUDED.purged_below,
            updated_at     = NOW();
    END IF;

    IF v_operational_only THEN
        SELECT jsonb_agg(jsonb_build_object(
            'table_name', sc.table_name,
            'record_id', sc.record_id,
            'operation', sc.operation,
            'payload', sc.payload,
            'server_version', sc.server_version,
            'created_at', sc.created_at
        ) ORDER BY sc.server_version ASC) INTO v_changes
        FROM sync_changes sc
        WHERE sc.farm_id = p_farm_id
          AND public.sync_can_read('worker', sc.table_name)
          AND sc.server_version > p_from_version
          AND (sc.operation = 'DELETE'
               OR public.sync_live_exists(sc.table_name, sc.record_id, sc.farm_id));

        SELECT COALESCE(MAX(server_version), p_from_version) INTO v_latest
        FROM sync_changes
        WHERE farm_id = p_farm_id
          AND public.sync_can_read('worker', table_name)
          AND server_version > p_from_version;

        SELECT COALESCE(MIN(server_version), v_latest) INTO v_min_keep
        FROM sync_changes
        WHERE farm_id = p_farm_id
          AND public.sync_can_read('worker', table_name);
    ELSE
        -- FIX (a): the filter was missing here. sync_can_read(system_admin, t)
        -- is "t NOT IN (users, farms)", so passing v_role through keeps the
        -- cross-tenant leak closed.
        SELECT jsonb_agg(jsonb_build_object(
            'table_name', sc.table_name,
            'record_id', sc.record_id,
            'operation', sc.operation,
            'payload', sc.payload,
            'server_version', sc.server_version,
            'created_at', sc.created_at
        ) ORDER BY sc.server_version ASC) INTO v_changes
        FROM sync_changes sc
        WHERE sc.farm_id = p_farm_id
          AND public.sync_can_read(COALESCE(v_role, 'system_admin'), sc.table_name)
          AND sc.server_version > p_from_version
          AND (sc.operation = 'DELETE'
               OR public.sync_live_exists(sc.table_name, sc.record_id, sc.farm_id));
    END IF;

    IF p_from_version > 0 AND p_from_version < v_min_keep THEN
        RETURN jsonb_build_object(
            'resync_required', true,
            'message', 'device is older than the retention window; full resync required',
            'latest_version', v_latest
        );
    END IF;

    RETURN jsonb_build_object(
        'resync_required', false,
        'latest_version', v_latest,
        'changes', COALESCE(v_changes, '[]'::jsonb)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.pull_remote_changes(uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pull_remote_changes(uuid, bigint) TO service_role;

-- ----------------------------------------------------------------------------
-- 7) refresh_sync_checkpoint.
--    The deployed version had no ownership check at all: p_all = true walked
--    every farm for any authenticated user, and p_farm_id accepted any farm.
--    A manager could rewrite another farm's checkpoint and force a resync, or
--    push a device past changes it must receive.
--    purged_below is MIN(server_version), never 0: a literal 0 tells every
--    device it is older than the retention window.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_sync_checkpoint(
    p_farm_id uuid DEFAULT NULL,
    p_all boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_farm  uuid;
    v_scope uuid;
BEGIN
    IF public.is_system_admin() THEN
        v_scope := p_farm_id;
    ELSE
        IF public.current_user_role() <> 'manager' THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: manager role required';
        END IF;
        IF p_all THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: p_all is admin only';
        END IF;
        v_farm := public.current_user_farm_id();
        IF p_farm_id IS NOT NULL AND p_farm_id IS DISTINCT FROM v_farm THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: foreign farm';
        END IF;
        v_scope := v_farm;
    END IF;

    IF v_scope IS NULL AND NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'VALIDATION_ERROR: farm required or p_all = true';
    END IF;

    INSERT INTO sync_checkpoint (farm_id, latest_version, purged_below, updated_at)
    SELECT sc.farm_id,
           MAX(sc.server_version),
           MIN(sc.server_version),
           NOW()
    FROM sync_changes sc
    WHERE (v_scope IS NULL OR sc.farm_id = v_scope)
    GROUP BY sc.farm_id
    ON CONFLICT (farm_id) DO UPDATE
        SET latest_version = EXCLUDED.latest_version,
            purged_below   = EXCLUDED.purged_below,
            updated_at     = NOW();

    RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_sync_checkpoint(uuid, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.refresh_sync_checkpoint(uuid, boolean) TO authenticated;

-- ----------------------------------------------------------------------------
-- 8) Backfill revenue.
--    revenue never had a trigger, so its history exists only as live rows. A
--    device sitting at a high watermark would never pull the old version, so
--    every live row is republished as a fresh INSERT carrying full state.
--    Idempotent: rows whose payload already matches are skipped.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_published int := 0;
BEGIN
    INSERT INTO sync_changes
        (table_name, record_id, operation, farm_id, user_id, payload)
    SELECT 'revenue', r.id, 'INSERT', r.farm_id, NULL,
           to_jsonb(r) - 'sync_status' - 'deleted_at'
    FROM revenue r
    WHERE r.deleted_at IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM sync_changes sc
          WHERE sc.table_name = 'revenue'
            AND sc.record_id = r.id
            AND sc.operation = 'INSERT'
            AND sc.payload = to_jsonb(r) - 'sync_status' - 'deleted_at'
      );

    GET DIAGNOSTICS v_published = ROW_COUNT;
    IF v_published > 0 THEN
        RAISE NOTICE 'sync_publish_revenue: republished % row(s)', v_published;
    END IF;
END;
$$;

COMMIT;
