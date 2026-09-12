-- ============================================================================
-- ترقية: العملة الديناميكية (دولار/ليرة) + مخزون صحون الكرتون
--
-- ملاحظة: ملف إضافي (additive) - لا يمسح أي بيانات.
-- يُطبَّق في محرر SQL الخاص بـ Supabase (SQL Editor).
--
-- 1) farms  : عمود حد التنبيه لمخزون صحون الكرتون (صحن)
-- 2) payments: عمودا العملة وسعر الصرف (تخزين بالدولار دائماً)
-- 3) expenses: عمودا العملة وسعر الصرف + عدد ربطات الكرتون المشتراة
-- 4) فئة مصروف جديدة: carton (صحون كرتون)
-- 5) إعادة إنشاء sync_records_batch مع السماح بالأعمدة الجديدة في المزامنة
-- ============================================================================

-- 1) حد التنبيه لمخزون صحون الكرتون في جدول المداجن
ALTER TABLE farms
    ADD COLUMN IF NOT EXISTS carton_low_threshold INTEGER NOT NULL DEFAULT 100;

-- 2) القبض: العملة وسعر الصرف (المبالغ تُخزَّن بالدولار وهو الأساسي)
ALTER TABLE payments
    ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT 'dollar'
        CHECK (currency IN ('dollar', 'lira')),
    ADD COLUMN IF NOT EXISTS exchange_rate NUMERIC(12,4);

-- 3) المصروفات: العملة وسعر الصرف + عدد ربطات الكرتون المشتراة
ALTER TABLE expenses
    ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT 'dollar'
        CHECK (currency IN ('dollar', 'lira')),
    ADD COLUMN IF NOT EXISTS exchange_rate NUMERIC(12,4),
    ADD COLUMN IF NOT EXISTS carton_bundles INTEGER;

-- 4) فئة مصروف جديدة: صحون كرتون (تشترى ربطات، الربطة = 100 صحن)
ALTER TABLE expenses
    DROP CONSTRAINT IF EXISTS expenses_category_check;
ALTER TABLE expenses
    ADD CONSTRAINT expenses_category_check CHECK (category IN (
        'electricity', 'water', 'labor', 'maintenance',
        'transport', 'feed', 'medicine', 'carton', 'other'
    ));

-- 5) إعادة إنشاء sync_records_batch مع السماح بالأعمدة الجديدة
CREATE OR REPLACE FUNCTION public.sync_records_batch(
    p_records jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    DECLARE
        v_result jsonb := '[]'::jsonb;
        v_record jsonb;
        v_data jsonb;
        v_table_name text;
        v_record_id uuid;
        v_operation text;
        v_operation_id text;
        v_user_farm uuid;
        v_user_role text;
        v_existing_record jsonb;
        v_new_version bigint;
        v_affected int := 0;
        v_skipped int := 0;
        v_errors int := 0;
        v_col text;
        v_allowed_cols text[];
        v_cols text[];
        v_vals text[];
        v_set_parts text[];
        v_sql text;
        v_upd_count int;
    BEGIN
        PERFORM set_config('app.skip_sync_trigger', 'on', true);

        v_user_farm := public.current_user_farm_id();
        v_user_role := public.current_user_role();
        IF v_user_farm IS NULL THEN
            RAISE EXCEPTION 'لا يمكن تحديد المزرعة للمستخدم الحالي';
        END IF;

        FOR v_record IN SELECT * FROM jsonb_array_elements(p_records)
        LOOP
            v_table_name  := v_record->>'table_name';
            v_record_id   := (v_record->>'record_id')::uuid;
            v_operation   := v_record->>'operation';
            v_operation_id := v_record->>'operation_id';
            v_data        := v_record->>'data';

            PERFORM set_config('app.device_id', COALESCE(v_record->>'device_id', ''), true);
            PERFORM set_config('app.correlation_id', COALESCE(v_record->>'correlation_id', ''), true);

            IF v_data IS NULL THEN
                v_data := '{}'::jsonb;
            END IF;

            IF v_operation_id IS NOT NULL AND length(v_operation_id) > 0 THEN
                DECLARE
                    v_prev_result jsonb;
                    v_mismatch int;
                BEGIN
                    SELECT result INTO v_prev_result
                    FROM idempotency_log
                    WHERE operation_id = v_operation_id
                      AND user_id = auth.uid()
                      AND farm_id = v_user_farm
                      AND table_name = v_table_name
                      AND record_id = v_record_id
                      AND operation = v_operation
                      AND status = 'done'
                    LIMIT 1;
                    IF v_prev_result IS NOT NULL THEN
                        v_result := v_result || v_prev_result;
                        CONTINUE;
                    END IF;

                    SELECT 1 INTO v_mismatch
                    FROM idempotency_log
                    WHERE operation_id = v_operation_id
                      AND NOT (
                          user_id = auth.uid()
                          AND farm_id = v_user_farm
                          AND table_name = v_table_name
                          AND record_id = v_record_id
                          AND operation = v_operation
                      )
                    LIMIT 1;
                    IF v_mismatch IS NOT NULL THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id,
                            'status', 'error',
                            'message', 'operation_id مستخدم بالفعل لعملية أخرى'
                        );
                        CONTINUE;
                    END IF;
                END;
            END IF;

            IF v_table_name IN ('users', 'farms') THEN
                v_errors := v_errors + 1;
                v_result := v_result || jsonb_build_object(
                    'record_id', v_record_id,
                    'status', 'error',
                    'message', 'جدول ممنوع للمزامنة عبر RPC: ' || v_table_name
                );
                CONTINUE;
            END IF;

            IF NOT public.sync_can_write(v_user_role, v_table_name) THEN
                v_errors := v_errors + 1;
                v_result := v_result || jsonb_build_object(
                    'record_id', v_record_id,
                    'status', 'error',
                    'message', 'الدور الحالي لا يملك صلاحية المزامنة للجدول: ' || v_table_name
                );
                CONTINUE;
            END IF;

            IF v_operation IN ('update', 'delete') THEN
                EXECUTE format(
                    'SELECT to_jsonb(t) FROM %I t WHERE t.id = $1 AND t.farm_id = $2',
                    v_table_name
                ) INTO v_existing_record
                USING v_record_id, v_user_farm;

                IF v_existing_record IS NULL THEN
                    v_skipped := v_skipped + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id,
                        'status', 'skipped',
                        'message', 'السجل غير موجود أو لا ينتمي للمزرعة'
                    );
                    CONTINUE;
                END IF;
            END IF;

            IF v_operation = 'update' AND v_existing_record IS NOT NULL THEN
                IF (v_record->>'previous_version') IS NOT NULL
                   AND (v_existing_record->>'version')::bigint > (v_record->>'previous_version')::bigint
                THEN
                    v_errors := v_errors + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id,
                        'status', 'conflict',
                        'server_version', (v_existing_record->>'version')::bigint,
                        'client_version', (v_record->>'previous_version')::bigint
                    );
                    CONTINUE;
                END IF;
            END IF;

            IF v_user_role = 'worker' AND v_operation IN ('update', 'delete') THEN
                IF (v_existing_record->>'worker_id') IS DISTINCT FROM auth.uid()::text THEN
                    v_errors := v_errors + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id,
                        'status', 'error',
                        'message', 'غير مصرح: لا يمكن تعديل/حذف سجل ليس من إنشائك'
                    );
                    CONTINUE;
                END IF;
            END IF;

            IF v_operation = 'delete' AND v_user_role <> 'manager' THEN
                v_errors := v_errors + 1;
                v_result := v_result || jsonb_build_object(
                    'record_id', v_record_id,
                    'status', 'error',
                    'message', 'غير مصرح: الحذف للمدير فقط'
                );
                CONTINUE;
            END IF;

            CASE v_table_name
                WHEN 'egg_production' THEN v_allowed_cols := ARRAY['flock_id','date','cartons','trays','loose_eggs','broken_eggs','dirty_eggs','tray_weight_kg','section_no','worker_id'];
                WHEN 'mortality' THEN v_allowed_cols := ARRAY['flock_id','date','count','reason','reason_other','notes','image_url','worker_id','section_no'];
                WHEN 'feed_consumption' THEN v_allowed_cols := ARRAY['flock_id','date','entry_mode','bags_count','quantity_kg','worker_id','section_no'];
                WHEN 'feed_received' THEN v_allowed_cols := ARRAY['flock_id','date','entry_mode','quantity','quantity_kg','feed_type','supplier','invoice_number','notes','price_per_kg','section_no','worker_id'];
                WHEN 'egg_dispatch' THEN v_allowed_cols := ARRAY['flock_id','date','customer_id','cartons','trays','tray_weight_kg','notes','payment_status','worker_id'];
                WHEN 'medications' THEN v_allowed_cols := ARRAY['flock_id','date','type','medicine_name','dosage','administration_route','treatment_days','withdrawal_days','notes','worker_id'];
                WHEN 'customers' THEN v_allowed_cols := ARRAY['name','phone','notes'];
                WHEN 'flocks' THEN v_allowed_cols := ARRAY['breed','start_date','initial_count','status','sections_count'];
                WHEN 'expenses' THEN v_allowed_cols := ARRAY['date','category','description','amount','currency','exchange_rate','carton_bundles'];
                WHEN 'inventory_items' THEN v_allowed_cols := ARRAY['name','unit','low_stock_threshold','notes'];
                WHEN 'inventory_transactions' THEN v_allowed_cols := ARRAY['item_id','date','type','quantity','note','user_id'];
                WHEN 'opening_balances' THEN v_allowed_cols := ARRAY['flock_id','eggs_produced','eggs_dispatched','feed_consumed_kg','initial_birds','mortality_count','total_payments','total_revenues','sections'];
                WHEN 'payments' THEN v_allowed_cols := ARRAY['dispatch_id','customer_id','date','price_per_carton','total_due','amount_paid','payment_method','currency','exchange_rate','due_date','notes','manager_id'];
                ELSE v_allowed_cols := ARRAY[]::text[];
            END CASE;

            IF v_user_role <> 'manager' THEN
                IF v_table_name = 'feed_received' THEN
                    v_allowed_cols := array_remove(v_allowed_cols, 'price_per_kg');
                ELSIF v_table_name = 'egg_dispatch' THEN
                    v_allowed_cols := array_remove(v_allowed_cols, 'payment_status');
                ELSIF v_table_name IN ('flocks', 'customers') THEN
                    v_allowed_cols := ARRAY[]::text[];
                END IF;
                v_allowed_cols := array_remove(v_allowed_cols, 'worker_id');
            END IF;

            IF v_operation IN ('insert', 'update') THEN
                IF v_table_name = 'egg_dispatch' AND (v_data ? 'customer_id') THEN
                    IF NOT EXISTS (SELECT 1 FROM customers WHERE id = (v_data->>'customer_id')::uuid AND farm_id = v_user_farm) THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id, 'status', 'error',
                            'message', 'customer_id لا ينتمي لمزرعتك'
                        );
                        CONTINUE;
                    END IF;
                END IF;

                IF v_table_name IN ('egg_production', 'mortality', 'feed_consumption', 'medications', 'opening_balances', 'feed_received', 'egg_dispatch')
                   AND (v_data ? 'flock_id') AND (v_data->>'flock_id') IS NOT NULL AND (v_data->>'flock_id') <> 'null' THEN
                    IF NOT EXISTS (SELECT 1 FROM flocks WHERE id = (v_data->>'flock_id')::uuid AND farm_id = v_user_farm) THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id, 'status', 'error',
                            'message', 'flock_id لا ينتمي لمزرعتك'
                        );
                        CONTINUE;
                    END IF;
                END IF;

                IF v_table_name = 'inventory_transactions' AND (v_data ? 'item_id') THEN
                    IF NOT EXISTS (SELECT 1 FROM inventory_items WHERE id = (v_data->>'item_id')::uuid AND farm_id = v_user_farm) THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id, 'status', 'error',
                            'message', 'item_id لا ينتمي لمزرعتك'
                        );
                        CONTINUE;
                    END IF;
                END IF;
            END IF;

            BEGIN
                IF v_operation = 'insert' THEN
                    v_cols := ARRAY['id', 'farm_id', 'version'];
                    v_vals := ARRAY[
                        quote_literal(v_record_id::text),
                        quote_literal(v_user_farm::text),
                        '1'
                    ];
                    FOR v_col IN SELECT jsonb_object_keys(v_data)
                    LOOP
                        IF v_col = ANY(v_allowed_cols) AND NOT (v_col = 'worker_id' AND v_user_role <> 'manager') THEN
                            v_cols := array_append(v_cols, v_col);
                            v_vals := array_append(v_vals, quote(v_data->>v_col));
                        END IF;
                    END LOOP;
                    IF v_user_role <> 'manager' THEN
                        v_cols := array_append(v_cols, 'worker_id');
                        v_vals := array_append(v_vals, quote_literal(auth.uid()::text));
                    END IF;
                    v_sql := format(
                        'INSERT INTO %I (%s) VALUES (%s)',
                        v_table_name,
                        array_to_string(v_cols, ', '),
                        array_to_string(v_vals, ', ')
                    );
                    EXECUTE v_sql;
                    v_affected := v_affected + 1;

                ELSIF v_operation = 'update' THEN
                    v_new_version := (v_existing_record->>'version')::bigint + 1;
                    v_set_parts := ARRAY[format('version = %s', v_new_version::text), 'updated_at = NOW()'];
                    FOR v_col IN SELECT jsonb_object_keys(v_data)
                    LOOP
                        IF v_col = ANY(v_allowed_cols) THEN
                            v_set_parts := array_append(v_set_parts, format('%I = %s', v_col, quote(v_data->>v_col)));
                        END IF;
                    END LOOP;
                    v_sql := format(
                        'UPDATE %I SET %s WHERE id = %s AND farm_id = %s AND version = %s',
                        v_table_name,
                        array_to_string(v_set_parts, ', '),
                        quote(v_record_id::text),
                        quote(v_user_farm::text),
                        quote((v_record->>'previous_version')::text)
                    );
                    EXECUTE v_sql;
                    GET DIAGNOSTICS v_upd_count = ROW_COUNT;
                    IF v_upd_count = 0 THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id,
                            'status', 'conflict',
                            'message', 'تعارض في الإصدار أثناء التحديث'
                        );
                        CONTINUE;
                    END IF;
                    v_affected := v_affected + v_upd_count;

                ELSIF v_operation = 'delete' THEN
                    EXECUTE format(
                        'UPDATE %I SET deleted_at = NOW(), updated_at = NOW(), version = version + 1 WHERE id = $1 AND farm_id = $2 AND version = $3 AND deleted_at IS NULL',
                        v_table_name
                    ) USING v_record_id, v_user_farm, (v_record->>'previous_version')::bigint;
                    GET DIAGNOSTICS v_upd_count = ROW_COUNT;
                    IF v_upd_count = 0 THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id,
                            'status', 'conflict',
                            'message', 'تعارض في الإصدار أثناء الحذف'
                        );
                        CONTINUE;
                    END IF;
                    v_affected := v_affected + v_upd_count;
                END IF;

                DECLARE
                    v_sc_record jsonb;
                    v_sc_payload jsonb;
                BEGIN
                    EXECUTE format(
                        'SELECT to_jsonb(t) FROM %I t WHERE t.id = $1 AND t.farm_id = $2',
                        v_table_name
                    ) INTO v_sc_record
                    USING v_record_id, v_user_farm;

                    IF v_sc_record IS NOT NULL THEN
                        v_sc_payload := v_sc_record - 'sync_status' - 'deleted_at';
                    ELSE
                        v_sc_payload := jsonb_build_object('id', v_record_id);
                    END IF;

                    INSERT INTO sync_changes (table_name, record_id, operation, farm_id, user_id, payload, device_id)
                    VALUES (v_table_name, v_record_id, upper(v_operation), v_user_farm, auth.uid(), v_sc_payload,
                            NULLIF(current_setting('app.device_id', true), ''));
                END;

                DECLARE
                    v_detail jsonb;
                BEGIN
                    v_detail := jsonb_build_object(
                        'record_id', v_record_id,
                        'table_name', v_table_name,
                        'status', 'ok',
                        'new_version', COALESCE(v_new_version, 1)
                    );
                    v_result := v_result || v_detail;

                    IF v_operation_id IS NOT NULL AND length(v_operation_id) > 0 THEN
                        INSERT INTO idempotency_log (operation_id, user_id, farm_id, table_name, record_id, operation, status, result)
                        VALUES (v_operation_id, auth.uid(), v_user_farm, v_table_name, v_record_id, v_operation, 'done', v_detail);
                    END IF;
                END;

            EXCEPTION WHEN OTHERS THEN
                v_errors := v_errors + 1;
                v_result := v_result || jsonb_build_object(
                    'record_id', v_record_id,
                    'status', 'error',
                    'message', SQLERRM
                );
            END;
        END LOOP;

        RETURN jsonb_build_object(
            'affected', v_affected,
            'skipped', v_skipped,
            'errors', v_errors,
            'details', v_result
        );
    END;
END;
$$;