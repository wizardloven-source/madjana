-- ============================================================================
-- 00801  farm_id transition: stop filing records under whichever farm happens
--        to be selected, without breaking clients that have not shipped yet.
-- ============================================================================
-- WHY A NEW MIGRATION
--   00800 is already applied to production and committed. Editing it would make
--   the file on disk disagree with what history says was applied, so the
--   correction lives here instead. Only sync_records_batch is replaced; every
--   other object from 00800 is untouched.
--
-- THE BUG
--   Farm resolution used to end with a fallback to current_user_farm_id() --
--   "the farm selected in the app right now". So a record created under farm A
--   was written under farm B the moment the user switched farms, and membership
--   checking did not help: the write was authorized, just filed in the wrong
--   place. That is silent misfiling, which is worse than a rejected write.
--
-- THE FIX, IN TRUST ORDER
--   1. payload       farm_id inside the record payload -- what the client bound
--                    the record to at creation time.
--   2. envelope      farm_id at the batch level.
--   3. existing_row  ONLY for UPDATE/DELETE: read the farm off the row that is
--                    already on the server. The record physically lives under
--                    exactly one farm there, so writing it back to that same
--                    farm cannot re-home anything. This is what keeps older
--                    clients working.
--   4. refuse.
--
--   INSERT has no source 3 by definition -- there is no row yet -- which is
--   exactly why it refuses instead of guessing. A refused INSERT stays in the
--   client's local queue; it is never lost.
--
--   Every resolved farm is then checked with user_has_farm_access before the
--   write, so a client-supplied farm_id cannot be used to reach another farm.
--
-- inventory_transactions has no farm_id column; its farm is resolved through
-- inventory_items.item_id.
--
-- Response details now carry farm_id_source (payload|envelope|existing_row),
-- so the rollout can be measured before source 3 is retired.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sync_records_batch(p_records jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
    v_rec            jsonb;
    v_record_id      uuid;
    v_table_name     text;
    v_operation      text;
    v_data           jsonb;
    v_active_farm    uuid;
    v_farm           uuid;   -- farm this record belongs to
    v_farm_source    text;   -- where that farm came from (observability)
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
    v_real_cols      text[];
    v_cols           text[];
    v_vals           text[];
    v_set_parts      text[];
    v_col            text;
    v_existing_ver   bigint;
    v_row_exists     boolean;
    v_prev_result    jsonb;
    v_id_mismatch    int;
    v_inserted       int;
    v_upd_count      int;
    v_force_worker_id boolean := false;
    v_del_count      int;
    v_schema_broken  text[];
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: not signed in';
    END IF;

    v_active_farm := current_user_farm_id();
    v_user_role   := current_user_role();

    IF v_active_farm IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: no farm bound to this user';
    END IF;

    SELECT array_agg(r.table_name) INTO v_schema_broken
    FROM public.sync_table_registry r
    WHERE to_regclass('public.' || r.table_name) IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                      WHERE a.attrelid = to_regclass('public.' || r.table_name)
                        AND a.attname = 'version'
                        AND a.attnum > 0 AND NOT a.attisdropped);

    FOR v_rec IN SELECT * FROM jsonb_array_elements(p_records) LOOP
        v_record_id    := NULLIF(v_rec->>'record_id', '')::uuid;
        v_table_name   := v_rec->>'table_name';
        v_operation    := upper(v_rec->>'operation');
        v_data         := COALESCE(v_rec->'data', '{}'::jsonb);
        v_operation_id := NULLIF(v_rec->>'operation_id', '');
        v_device       := NULLIF(v_rec->>'device_id', '');
        v_prev_version := NULLIF(v_rec->>'previous_version', '')::bigint;
        v_force_worker_id := false;

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

        -- ── THE FIX ──────────────────────────────────────────────────────────
        -- ── Determine the farm this record belongs to ──────────────────────────
        -- NEVER fall back to current_user_farm_id(). That fallback is what
        -- re-homed records to whichever farm happened to be selected at upload
        -- time: a row created under farm A got filed under farm B the moment
        -- the user switched. That is data corruption, and no amount of
        -- membership checking fixes it -- the write is merely authorized.
        --
        -- Sources, in order of trustworthiness:
        --   1. payload      -- the farm the client bound the record to.
        --   2. envelope     -- same value carried at the batch level.
        --   3. existing row -- ONLY for UPDATE/DELETE, where the row is already
        --                      on the server under exactly one farm. Reading it
        --                      back is not a guess: the record is physically
        --                      there, and writing it to that same farm cannot
        --                      re-home anything.
        --   4. refuse.
        --
        -- INSERT has no source 3 by definition (the row does not exist yet),
        -- which is exactly why it refuses rather than guessing.
        v_farm := COALESCE(
            NULLIF(v_data->>'farm_id', '')::uuid,
            NULLIF(v_rec->>'farm_id', '')::uuid
        );
        v_farm_source := CASE
            WHEN v_farm IS NOT NULL AND NULLIF(v_data->>'farm_id', '') IS NOT NULL
                THEN 'payload'
            WHEN v_farm IS NOT NULL THEN 'envelope'
            ELSE 'none'
        END;

        IF v_farm IS NULL AND v_operation IN ('UPDATE', 'DELETE') THEN
            -- Read the farm off the row that is already on the server. Safe for
            -- data integrity: the record already belongs to this farm, and we
            -- are writing it back to the farm it is already in.
            --
            -- inventory_transactions has no farm_id of its own -- it inherits
            -- the farm through its parent inventory item, which is how its RLS
            -- policy scopes it. Reading farm_id from it directly would raise,
            -- so it joins through the item. Any other unexpected failure leaves
            -- v_farm NULL, and the record is refused rather than guessed.
            IF v_table_name = 'inventory_transactions' THEN
                BEGIN
                    EXECUTE
                        'SELECT i.farm_id
                           FROM public.inventory_transactions t
                           JOIN public.inventory_items i ON i.id = t.item_id
                          WHERE t.id = $1
                            AND t.deleted_at IS NULL
                            AND i.deleted_at IS NULL'
                        INTO v_farm USING v_record_id;
                EXCEPTION WHEN OTHERS THEN
                    v_farm := NULL;
                END;
            ELSE
                BEGIN
                    EXECUTE format(
                        'SELECT farm_id FROM public.%I
                          WHERE id = $1 AND deleted_at IS NULL',
                        v_table_name
                    ) INTO v_farm USING v_record_id;
                EXCEPTION WHEN OTHERS THEN
                    v_farm := NULL;
                END;
            END IF;

            IF v_farm IS NOT NULL THEN
                v_farm_source := 'existing_row';
            END IF;
        END IF;

        IF v_farm IS NULL THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'error',
                'farm_id_source', 'none',
                'message', CASE
                    WHEN v_operation = 'INSERT'
                        THEN 'AUTHORIZATION_DENIED: INSERT states no farm_id and '
                             || 'no existing row exists to read one from; '
                             || 'refusing to guess the caller''s active farm'
                    ELSE 'AUTHORIZATION_DENIED: no farm_id given and the record '
                         || 'does not exist on the server'
                END
            );
            CONTINUE;
        END IF;

        IF NOT public.user_has_farm_access(v_farm) THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'error',
                'message', 'AUTHORIZATION_DENIED: not a member of farm ' || v_farm::text
            );
            CONTINUE;
        END IF;
        -- ─────────────────────────────────────────────────────────────────────

        IF v_operation_id IS NOT NULL THEN
            SELECT r.result INTO v_prev_result
            FROM public.idempotency_log r
            WHERE r.operation_id = v_operation_id
              AND r.user_id   = auth.uid()
              AND r.farm_id    = v_farm
              AND r.table_name = v_table_name
              AND r.record_id  = v_record_id
              AND r.operation  = v_operation
              AND r.status     = 'done'
            LIMIT 1;

            IF v_prev_result IS NOT NULL THEN
                v_skipped := v_skipped + 1;
                v_result  := v_result || v_prev_result;
                CONTINUE;
            END IF;

            SELECT 1 INTO v_id_mismatch
            FROM public.idempotency_log r
            WHERE r.operation_id = v_operation_id
              AND NOT (r.user_id   IS NOT DISTINCT FROM auth.uid()
                   AND r.farm_id    IS NOT DISTINCT FROM v_farm
                   AND r.table_name = v_table_name
                   AND r.record_id  IS NOT DISTINCT FROM v_record_id
                   AND r.operation  = v_operation)
            LIMIT 1;

            IF v_id_mismatch IS NOT NULL THEN
                v_errors := v_errors + 1;
                v_result := v_result || jsonb_build_object(
                    'record_id', v_record_id,
                    'table_name', v_table_name,
                    'operation_id', v_operation_id,
                    'status', 'error',
                    'message', 'IDEMPOTENCY_MISMATCH: operation_id already used'
                              || ' for a different record'
                );
                CONTINUE;
            END IF;
        END IF;

        IF v_schema_broken IS NOT NULL
           AND v_table_name = ANY(v_schema_broken) THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'error',
                'message', 'SYNC_SCHEMA_MISSING: table ' || v_table_name
                          || ' has no version column - apply'
                          || ' migration 20260926000700_sync_registry.sql'
            );
            CONTINUE;
        END IF;

        CASE v_table_name
            WHEN 'flocks' THEN v_allowed_cols := ARRAY['breed','start_date','initial_count','current_count','status','sections_count'];
            WHEN 'egg_production' THEN v_allowed_cols := ARRAY['flock_id','date','cartons','trays','loose_eggs','total_eggs','broken_eggs','dirty_eggs','tray_weight_kg','section_no','worker_id'];
            WHEN 'mortality' THEN v_allowed_cols := ARRAY['flock_id','date','count','reason','reason_other','notes','image_url','section_no','worker_id'];
            WHEN 'feed_consumption' THEN v_allowed_cols := ARRAY['flock_id','date','entry_mode','bags_count','quantity_kg','section_no','worker_id'];
            WHEN 'feed_received' THEN v_allowed_cols := ARRAY['flock_id','date','entry_mode','quantity','quantity_kg','feed_type','supplier','invoice_number','notes','price_per_kg','section_no','worker_id'];
            WHEN 'egg_dispatch' THEN v_allowed_cols := ARRAY['flock_id','date','customer_id','cartons','trays','total_eggs','tray_weight_kg','notes','payment_status','worker_id'];
            WHEN 'medications' THEN v_allowed_cols := ARRAY['flock_id','date','type','medicine_name','dosage','administration_route','treatment_days','withdrawal_days','notes','worker_id'];
            WHEN 'expenses' THEN v_allowed_cols := ARRAY['date','category','description','amount','currency','exchange_rate','carton_bundles'];
            WHEN 'inventory_items' THEN v_allowed_cols := ARRAY['name','unit','low_stock_threshold','notes','flock_id'];
            WHEN 'inventory_transactions' THEN v_allowed_cols := ARRAY['item_id','date','type','quantity','note','user_id'];
            WHEN 'opening_balances' THEN v_allowed_cols := ARRAY['eggs_produced','eggs_dispatched','feed_consumed_kg','initial_birds','mortality_count','total_payments','total_revenues','sections'];
            WHEN 'payments' THEN v_allowed_cols := ARRAY['dispatch_id','customer_id','date','price_per_carton','total_due','amount_paid','payment_method','currency','exchange_rate','due_date','notes','manager_id'];
            WHEN 'revenue' THEN v_allowed_cols := ARRAY['date','category','description','amount','currency','exchange_rate','quantity','unit','reference_id','worker_id'];
            WHEN 'stock_adjustments' THEN v_allowed_cols := ARRAY['stock_type','delta_qty','reason','notes','date','manager_id'];
            WHEN 'dispatch_requests'
            THEN v_allowed_cols := CASE
                    WHEN v_user_role = 'manager'
                        THEN ARRAY['flock_id','customer_id','cartons','trays',
                                    'total_eggs','stock_eggs','status','worker_id',
                                    'decided_at','decided_by']
                    ELSE ARRAY['flock_id','customer_id','cartons','trays',
                                'total_eggs','stock_eggs']
                END;
            WHEN 'customers' THEN v_allowed_cols := ARRAY['name','phone','notes'];
            ELSE v_allowed_cols := ARRAY[]::text[];
        END CASE;

        -- farm_id is never a client-writable column: it is decided by the
        -- membership check above, not by the payload.
        v_allowed_cols := array_remove(COALESCE(v_allowed_cols, ARRAY[]::text[]), 'farm_id');

        IF v_user_role <> 'manager' THEN
            IF v_table_name = 'feed_received' THEN
                v_allowed_cols := array_remove(v_allowed_cols, 'price_per_kg');
            ELSIF v_table_name = 'egg_dispatch' THEN
                v_allowed_cols := array_remove(v_allowed_cols, 'payment_status');
            ELSIF v_table_name IN ('flocks', 'customers') THEN
                v_allowed_cols := ARRAY[]::text[];
            END IF;
            IF v_user_role = 'worker' THEN
                -- A worker must not be able to record somebody else's id, but
                -- worker_id is NOT NULL on every operational table. Stripping it
                -- outright made the INSERT fail on the NOT NULL constraint, so a
                -- worker could never log mortality/egg production/feed at all.
                -- It is removed here and re-injected as auth.uid() below.
                v_allowed_cols := array_remove(v_allowed_cols, 'worker_id');
                v_force_worker_id := true;
            END IF;
        END IF;

        SELECT array_agg(c.column_name) INTO v_real_cols
        FROM information_schema.columns c
        WHERE c.table_schema = 'public'
          AND c.table_name   = v_table_name;

        IF v_real_cols IS NOT NULL THEN
            v_allowed_cols := ARRAY(
                SELECT unnest(v_allowed_cols)
                INTERSECT
                SELECT unnest(v_real_cols)
            );
        END IF;

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
                EXECUTE format(
                    'SELECT 1 FROM %I WHERE id = $1 AND farm_id = $2 LIMIT 1',
                    v_table_name
                ) INTO v_row_exists USING v_record_id, v_farm;

                v_row_exists := (v_row_exists IS NOT NULL);

                IF v_row_exists THEN
                    EXECUTE format(
                        'SELECT version FROM %I WHERE id = $1 AND farm_id = $2',
                        v_table_name
                    ) INTO v_existing_ver USING v_record_id, v_farm;
                END IF;

                v_cols := ARRAY['id','farm_id','version'];
                v_vals := ARRAY[
                    quote_literal(v_record_id::text),
                    quote_literal(v_farm::text),
                    '1'
                ];
                FOR v_col IN SELECT jsonb_object_keys(v_data) LOOP
                    IF v_col = ANY(v_allowed_cols) THEN
                        v_cols := array_append(v_cols, v_col);
                        v_vals := array_append(v_vals, quote_nullable(v_data->>v_col));
                    END IF;
                END LOOP;

                -- A worker always authors as themselves; worker_id was stripped
                -- from the payload above so it cannot be spoofed.
                IF v_force_worker_id
                   AND EXISTS (SELECT 1 FROM information_schema.columns c
                                WHERE c.table_schema = 'public'
                                  AND c.table_name   = v_table_name
                                  AND c.column_name  = 'worker_id') THEN
                    IF 'worker_id' = ANY(v_cols) THEN
                        v_vals[array_position(v_cols, 'worker_id')] := quote_nullable(auth.uid()::text);
                    ELSE
                        v_cols := array_append(v_cols, 'worker_id');
                        v_vals := array_append(v_vals, quote_nullable(auth.uid()::text));
                    END IF;
                END IF;

                IF v_row_exists THEN
                    v_existing_ver := COALESCE(v_existing_ver, 1);

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
                        quote_nullable(v_farm::text)
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

                IF v_prev_version IS NULL THEN
                    EXECUTE format(
                        'UPDATE %I SET %s, version = version + 1, updated_at = NOW()
                         WHERE id = %s AND farm_id = %s',
                        v_table_name,
                        array_to_string(v_set_parts, ', '),
                        quote_nullable(v_record_id::text),
                        quote_nullable(v_farm::text)
                    );
                ELSE
                    EXECUTE format(
                        'UPDATE %I SET %s, version = version + 1, updated_at = NOW()
                         WHERE id = %s AND farm_id = %s AND version = %s',
                        v_table_name,
                        array_to_string(v_set_parts, ', '),
                        quote_nullable(v_record_id::text),
                        quote_nullable(v_farm::text),
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
                    quote_nullable(v_farm::text)
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

            SELECT sc.server_version INTO v_new_version
            FROM public.sync_changes sc
            WHERE sc.table_name = v_table_name
              AND sc.record_id  = v_record_id
            ORDER BY sc.server_version DESC
            LIMIT 1;

            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'ok',
                'new_version', COALESCE(v_new_version, 1),
                -- Observability for the phase-2 measurement: how many uploads
                -- still arrive from clients too old to send farm_id. When
                -- 'existing_row' stops appearing, it is safe to make farm_id
                -- mandatory for everyone.
                'farm_id_source', v_farm_source
            );

            IF v_operation_id IS NOT NULL AND length(v_operation_id) > 0 THEN
                INSERT INTO idempotency_log
                    (operation_id, user_id, farm_id, table_name, record_id, operation, status, result)
                VALUES
                    (v_operation_id, auth.uid(), v_farm, v_table_name,
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

            IF v_operation_id IS NOT NULL AND length(v_operation_id) > 0 THEN
                INSERT INTO public.idempotency_log
                    (operation_id, user_id, farm_id, table_name, record_id,
                     operation, status, result)
                VALUES
                    (v_operation_id, auth.uid(), v_farm,
                     COALESCE(NULLIF(v_table_name, ''), 'unknown'),
                     COALESCE(v_record_id,
                              '00000000-0000-0000-0000-000000000000'::uuid),
                     COALESCE(v_operation, 'unknown'), 'error',
                     jsonb_build_object('message', SQLERRM))
                ON CONFLICT (operation_id) DO NOTHING;
            END IF;
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'affected', v_affected,
        'skipped',  v_skipped,
        'errors',   v_errors,
        'details',  v_result
    );
END;
$fn$;
