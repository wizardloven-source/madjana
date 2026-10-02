-- ============================================================================
-- 20260926000700 - root fix: one owner for the sync table contract.
--
-- The failure this kills
-- ----------------------
-- egg_production had no `version` column, so every write to it died with
--     ERROR: column "version" does not exist
-- 00500 and 00600 each carried their own copy of the "make sure every synced
-- table has version/updated_at/deleted_at" block, and each copy was
-- incomplete. Nothing owned the invariant, so a table could be silently left
-- behind and the whole sync path would fail on every device with no SQL
-- footprint (idempotency_log only ever received successes).
--
-- What changes
-- ------------
-- 1. sync_table_registry becomes the single source of truth for "which tables
--    sync owns". The column guard and the function's preflight both read it,
--    so there is exactly one list to maintain instead of four.
-- 2. The guard now VERIFIES after adding, and RAISES with the exact list of
--    offenders. A future migration can no longer ship a half-fixed contract.
-- 3. sync_records_batch preflights the registry and returns a precise
--    per-record error for a table missing `version`, so one broken table no
--    longer takes the other fifteen down, and the message names the fix.
-- 4. Failed records are now written to idempotency_log with status='error'.
--    The next outage is queryable instead of invisible.
--
-- The per-table column allow list is deliberately still hard-coded: it encodes
-- policy (a worker may not write financial columns, customers.is_global is
-- never client-writable). Deriving it from pg_attribute would silently widen
-- the write surface. What is new is that the allow list is now AUDITED at
-- deploy time, so a column that does not exist is reported loudly instead of
-- being discovered months later as a silently dropped field.
--
-- ASCII only.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. The registry: the one list that says "sync owns these tables".
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sync_table_registry (
    table_name text PRIMARY KEY,
    sort_order int NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.sync_table_registry (table_name, sort_order) VALUES
    ('flocks', 1),
    ('customers', 2),
    ('egg_production', 3),
    ('mortality', 4),
    ('feed_consumption', 5),
    ('feed_received', 6),
    ('egg_dispatch', 7),
    ('medications', 8),
    ('expenses', 9),
    ('inventory_items', 10),
    ('inventory_transactions', 11),
    ('opening_balances', 12),
    ('payments', 13),
    ('revenue', 14),
    ('stock_adjustments', 15),
    ('dispatch_requests', 16)
ON CONFLICT (table_name) DO UPDATE SET sort_order = EXCLUDED.sort_order;

-- ---------------------------------------------------------------------------
-- 2. The guard: add what is missing, then PROVE it is all there.
-- ---------------------------------------------------------------------------
DO $guard$
DECLARE
    v_table  text;
    v_col    text;
    v_kind   "char";
    v_added  int := 0;
    v_broken text[] := ARRAY[]::text[];
BEGIN
    -- FOREACH only accepts an array; iterating the registry needs FOR ... IN.
    FOR v_table IN
        SELECT table_name FROM public.sync_table_registry ORDER BY sort_order
    LOOP
        SELECT c.relkind INTO v_kind
        FROM pg_class c WHERE c.oid = to_regclass('public.' || v_table);

        CONTINUE WHEN v_kind IS NULL;                 -- table absent here
        CONTINUE WHEN v_kind NOT IN ('r', 'p');      -- view: not ours to alter

        FOREACH v_col IN ARRAY ARRAY['version', 'updated_at', 'deleted_at'] LOOP
            IF NOT EXISTS (SELECT 1 FROM pg_attribute
                           WHERE attrelid = to_regclass('public.' || v_table)
                             AND attname = v_col
                             AND attnum > 0 AND NOT attisdropped) THEN
                EXECUTE format('ALTER TABLE public.%I ADD COLUMN %I '
                               || CASE v_col
                                    WHEN 'version'    THEN 'BIGINT NOT NULL DEFAULT 1'
                                    ELSE 'TIMESTAMPTZ'
                                  END,
                               v_table, v_col);
                v_added := v_added + 1;
                RAISE NOTICE 'added %.%', v_table, v_col;
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE '20260926000700: % column(s) added', v_added;

    -- Loud verification. This is the part every previous copy lacked: if the
    -- contract is still incomplete, say exactly which table and column, and
    -- refuse to let the migration pass silently.
    FOR v_table, v_col IN
        SELECT r.table_name, c.col
        FROM public.sync_table_registry r
        CROSS JOIN unnest(ARRAY['version', 'updated_at', 'deleted_at']) AS c(col)
        WHERE to_regclass('public.' || r.table_name) IS NOT NULL
          AND EXISTS (SELECT 1 FROM pg_class k
                      WHERE k.oid = to_regclass('public.' || r.table_name)
                        AND k.relkind IN ('r', 'p'))
          AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                          WHERE a.attrelid = to_regclass('public.' || r.table_name)
                            AND a.attname = c.col
                            AND a.attnum > 0 AND NOT a.attisdropped)
        ORDER BY 1, 2
    LOOP
        v_broken := v_broken || (v_table || '.' || v_col);
    END LOOP;

    IF array_length(v_broken, 1) IS NOT NULL THEN
        RAISE EXCEPTION
            'SYNC_CONTRACT_INCOMPLETE: still missing % - fix these before syncing',
            array_to_string(v_broken, ', ');
    END IF;

    RAISE NOTICE '20260926000700: sync contract verified for all % table(s)',
                 (SELECT count(*) FROM public.sync_table_registry);
END;
$guard$;

-- ---------------------------------------------------------------------------
-- 3. sync_records_batch: precise preflight + failures that are queryable.
-- ---------------------------------------------------------------------------
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
    v_del_count      int;
    v_schema_broken  text[];
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: not signed in';
    END IF;

    v_user_farm := current_user_farm_id();
    v_user_role := current_user_role();

    IF v_user_farm IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: no farm bound to this user';
    END IF;

    -- Root-cause guard. The batch used to die deep inside dynamic SQL with
    -- "column ""version"" does not exist", once per record, with nothing
    -- queryable afterwards. Detect the broken tables up front so each record
    -- gets a precise, actionable message -- and so ONE bad table cannot take
    -- the other fifteen down with it.
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

        -- FIX (d): replay protection. UPGRADE_sync_idempotent_insert.sql used to
        -- do this and it was lost in the 00100/00400/00500/00600 rewrites, so
        -- idempotency_log only RECORDED operations -- it never prevented them.
        -- Resending a batch (dropped connection, a restarted app, a double tap
        -- on Sync) therefore re-applied every write: `version = version + 1`
        -- kept climbing, counters and stock movements doubled, and
        -- inventory_transactions / payments were duplicated outright.
        IF v_operation_id IS NOT NULL THEN
            SELECT r.result INTO v_prev_result
            FROM public.idempotency_log r
            WHERE r.operation_id = v_operation_id
              AND r.user_id   = auth.uid()
              AND r.farm_id    = v_user_farm
              AND r.table_name = v_table_name
              AND r.record_id  = v_record_id
              AND r.operation  = v_operation
              AND r.status     = 'done'
            LIMIT 1;

            IF v_prev_result IS NOT NULL THEN
                -- Already applied: replay the original answer verbatim so the
                -- client sees the same new_version it got the first time.
                v_skipped := v_skipped + 1;
                v_result  := v_result || v_prev_result;
                CONTINUE;
            END IF;

            -- Same operation_id pointed at a DIFFERENT record: that is a client
            -- bug or a forged id, and honouring it would corrupt the wrong row.
            SELECT 1 INTO v_id_mismatch
            FROM public.idempotency_log r
            WHERE r.operation_id = v_operation_id
              AND NOT (r.user_id   IS NOT DISTINCT FROM auth.uid()
                   AND r.farm_id    IS NOT DISTINCT FROM v_user_farm
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
                -- The worker creates the request, so it must be allowed to
                -- broadcast. status / decided_* stay manager-only: approving a
                -- dispatch is a manager decision, not a worker one.
                THEN v_allowed_cols := CASE
                    WHEN v_user_role = 'manager'
                        THEN ARRAY['flock_id','customer_id','cartons','trays',
                                    'total_eggs','stock_eggs','status','worker_id',
                                    'decided_at','decided_by']
                    ELSE ARRAY['flock_id','customer_id','cartons','trays',
                                'total_eggs','stock_eggs']
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

        -- Permanent guard: intersect with the table's real columns.
        -- A typo or a stale name in v_allowed_cols can no longer produce
        -- "column does not exist" and lose the write: the phantom is simply
        -- dropped. Correctness of the list still matters -- a missing real
        -- column is dropped too, and that is silent, so the lists above must
        -- stay in step with information_schema.
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
                --
                -- Read only `version`, into a typed bigint. Reading the whole
                -- row into an anonymous RECORD made PL/pgSQL fail with
                -- "could not identify column version in record data type".
                -- Capture existence explicitly (EXECUTE...INTO does NOT clear/set
                -- FOUND reliably for 0-row results on all versions). We must test
                -- for a row ourselves to avoid treating a non-existent INSERT as
                -- an UPDATE.
                EXECUTE format(
                    'SELECT 1 FROM %I WHERE id = $1 AND farm_id = $2 LIMIT 1',
                    v_table_name
                ) INTO v_row_exists USING v_record_id, v_user_farm;

                v_row_exists := (v_row_exists IS NOT NULL);

                -- Only fetch the current version if the row actually exists.
                IF v_row_exists THEN
                    EXECUTE format(
                        'SELECT version FROM %I WHERE id = $1 AND farm_id = $2',
                        v_table_name
                    ) INTO v_existing_ver USING v_record_id, v_user_farm;
                END IF;

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

            -- FIX (c): the column here is `server_version`, NOT `version`.
            -- `sync_changes` has no `version` column at all (its columns are
            -- id, table_name, record_id, operation, farm_id, device_id,
            -- user_id, payload, server_version, created_at). Reading
            -- `version` raised "column \"version\" does not exist" on every
            -- successful write, which surfaced as {affected:1, errors:1}:
            -- the write committed, then the post-success version read threw
            -- and was caught as a per-record error. `server_version` is the
            -- value the client needs as `new_version` anyway.
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

            -- A failed write used to be invisible: idempotency_log only
            -- ever received successes, so the outage had no SQL footprint.
            IF v_operation_id IS NOT NULL AND length(v_operation_id) > 0 THEN
                INSERT INTO public.idempotency_log
                    (operation_id, user_id, farm_id, table_name, record_id,
                     operation, status, result)
                VALUES
                    (v_operation_id, auth.uid(), v_user_farm,
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
$$;

-- ---------------------------------------------------------------------------
-- 4. Audit the allow list against the real schema.
--
-- 00500 had to repair nine tables whose allow list named columns that had
-- never existed, and nothing noticed: the runtime guard silently dropped them,
-- so the only symptom was a field that never synced. This reads the allow
-- list back out of the function body and reports any name with no matching
-- column.
--
-- Reported as a NOTICE, not an exception, on purpose. A phantom column is
-- already harmless (00500's INTERSECT drops it); blocking every deployment
-- over a typo would cost more than it protects. dispatch_requests is skipped
-- because its allow list is a role-dependent CASE rather than a literal.
-- ---------------------------------------------------------------------------
DO $audit$
DECLARE
    v_body text;
    v_hit  record;
    v_col  text;
    v_bad  text[] := ARRAY[]::text[];
    v_n    int := 0;
BEGIN
    SELECT p.prosrc INTO v_body
    FROM pg_proc p
    WHERE p.oid = to_regprocedure('public.sync_records_batch(jsonb)');

    IF v_body IS NULL THEN
        RAISE NOTICE '20260926000700: could not read function body, audit skipped';
        RETURN;
    END IF;

    FOR v_hit IN
        SELECT m[1] AS tbl, m[2] AS cols
        FROM regexp_matches(
                 v_body,
                 'WHEN ''([a-z_]+)'' THEN v_allowed_cols := ARRAY\[([^\]]*)\]',
                 'g') AS m
    LOOP
        FOREACH v_col IN ARRAY string_to_array(v_hit.cols, ',') LOOP
            v_col := btrim(v_col, chr(39));
            CONTINUE WHEN v_col = '';

            IF to_regclass('public.' || v_hit.tbl) IS NULL THEN
                CONTINUE;
            END IF;

            IF NOT EXISTS (SELECT 1 FROM pg_attribute a
                           WHERE a.attrelid = to_regclass('public.' || v_hit.tbl)
                             AND a.attname = v_col
                             AND a.attnum > 0 AND NOT a.attisdropped) THEN
                v_bad := v_bad || (v_hit.tbl || '.' || v_col);
            END IF;
        END LOOP;
    END LOOP;

    v_n := COALESCE(array_length(v_bad, 1), 0);
    IF v_n > 0 THEN
        RAISE NOTICE
            '20260926000700: allow list names % column(s) that DO NOT EXIST: %',
            v_n, array_to_string(v_bad, ', ');
    ELSE
        RAISE NOTICE '20260926000700: every allow-listed column exists';
    END IF;
END;
$audit$;

COMMIT;
