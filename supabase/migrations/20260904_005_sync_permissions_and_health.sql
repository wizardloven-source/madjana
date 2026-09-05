-- ============================================================
-- Migration 20260904_005: توحيد صلاحيات المزامنة + صحة المزامنة
-- ============================================================
-- يضيف:
--   1) sync_can_write(role,table)  — مصفوفة صلاحيات كتابة مركزية (كانت NOT IN مبعثرة)
--   2) sync_can_read(role,table)   — مصفوفة صلاحيات قراءة/سحب مركزية
--   3) admin_sync_health()         — صحة مزامنة كل المداجن (لـ system_admin)
--
-- ملاحظة: الـ migrations التالية (source SQL) أُعيد كتابة الفونكتين
-- sync_records_batch و pull_remote_changes لاستخدام هاتين الدالتين المركزيتين.
-- يجب تطبيق هذا الملف قبل/بعد نشر الـ rework للفونكتين معاً.
-- ============================================================

-- 1) sync_can_write
CREATE OR REPLACE FUNCTION public.sync_can_write(p_role text, p_table text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT
        CASE p_role
            WHEN 'worker' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications'
            )
            WHEN 'manager' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications',
                'customers', 'flocks', 'expenses', 'payments',
                'inventory_items', 'inventory_transactions',
                'opening_balances'
            )
            WHEN 'system_admin' THEN p_table NOT IN ('users', 'farms')
            ELSE false
        END;
$$;

-- 2) sync_can_read
CREATE OR REPLACE FUNCTION public.sync_can_read(p_role text, p_table text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT
        CASE p_role
            WHEN 'worker' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications'
            )
            WHEN 'manager' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications',
                'customers', 'flocks', 'expenses', 'payments',
                'inventory_items', 'inventory_transactions',
                'opening_balances'
            )
            WHEN 'system_admin' THEN p_table NOT IN ('users', 'farms')
            ELSE false
        END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_can_write(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_can_read(text, text) TO authenticated;

-- 3) admin_sync_health
CREATE OR REPLACE FUNCTION public.admin_sync_health(
    p_online_window_minutes int DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result jsonb;
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'غير مصرح: هذه البيانات لـ system_admin فقط';
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'farm_id',       h.farm_id,
        'farm_name',     h.farm_name,
        'device_count',  h.device_count,
        'online_devices', h.online_devices,
        'offline_devices', (h.device_count - h.online_devices),
        'pending_conflicts', h.pending_conflicts,
        'last_sync',     h.last_sync,
        'latest_version', h.latest_version
    )), '[]'::jsonb) INTO v_result
    FROM (
        SELECT
            f.id   AS farm_id,
            f.name AS farm_name,
            COALESCE(d.device_count, 0)   AS device_count,
            COALESCE(d.online_devices, 0) AS online_devices,
            COALESCE(c.pending_conflicts, 0) AS pending_conflicts,
            COALESCE(d.last_sync, f.created_at) AS last_sync,
            COALESCE(cp.latest_version, 0) AS latest_version
        FROM public.farms f
        LEFT JOIN (
            SELECT
                dd.farm_id,
                COUNT(*)   AS device_count,
                COUNT(*) FILTER (WHERE dd.last_seen >= NOW() - (p_online_window_minutes * interval '1 minute'))
                           AS online_devices,
                MAX(dd.last_seen) AS last_sync
            FROM (
                SELECT
                    sc.farm_id,
                    sc.device_id,
                    MAX(sc.created_at) AS last_seen
                FROM public.sync_changes sc
                WHERE sc.device_id IS NOT NULL AND sc.device_id <> ''
                GROUP BY sc.farm_id, sc.device_id
            ) dd
            GROUP BY dd.farm_id
        ) d ON d.farm_id = f.id
        LEFT JOIN (
            SELECT farm_id, COUNT(*) AS pending_conflicts
            FROM public.sync_conflicts
            WHERE status = 'pending'
            GROUP BY farm_id
        ) c ON c.farm_id = f.id
        LEFT JOIN public.sync_checkpoint cp ON cp.farm_id = f.id
        ORDER BY f.created_at
    ) h;

    IF v_result IS NULL THEN v_result := '[]'::jsonb; END IF;
    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_sync_health(int) TO authenticated;

-- ============================================================
-- 4) sync_records_batch — نسخة مُعاد كتابتها تستخدم sync_can_write
--    (مصفوفة الصلاحيات المركزية) بدلاً من NOT IN المبعثرة لكل دور.
-- ============================================================
CREATE OR REPLACE FUNCTION public.sync_records_batch(
    p_records jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
    -- تعطيل الـ trigger المُولِّد لـ sync_changes أثناء الدفعة
    -- لمنع التكرار (العمليات تُكتب عبر sync_records_batch ولا حاجة لتكرارها)
    PERFORM set_config('app.skip_sync_trigger', 'on', true);

    v_user_farm := public.current_user_farm_id();
    v_user_role := public.current_user_role();
    -- P0 معماري: system_admin لا يحتاج farm_id للمزامنة المركزية
    IF v_user_farm IS NULL AND NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'لا يمكن تحديد المزرعة للمستخدم الحالي';
    END IF;

    FOR v_record IN SELECT * FROM jsonb_array_elements(p_records)
    LOOP
        v_table_name  := v_record->>'table_name';
        v_record_id   := (v_record->>'record_id')::uuid;
        v_operation   := v_record->>'operation';
        v_operation_id := v_record->>'operation_id';
        v_data        := v_record->>'data';

        -- (19) تمرير device_id/correlation_id إلى GUC ليقرأها audit trigger
        -- (null-safe: إذا لم تُرسل تبقى تلقائيات NULL).
        PERFORM set_config('app.device_id', COALESCE(v_record->>'device_id', ''), true);
        PERFORM set_config('app.correlation_id', COALESCE(v_record->>'correlation_id', ''), true);

        IF v_data IS NULL THEN
            v_data := '{}'::jsonb;
        END IF;

        -- Idempotency check: إذا تم تنفيذ العملية مسبقاً بواسطة هذا المستخدم
        -- ونفس الصف/الجدول/العملية، أرجع النتيجة المحفوظة.
        -- P0: نطاق الـ operation_id = (المستخدم + المزرعة + الصف + الجدول + العملية)
        -- حتى لا يُعاد استعمال operation_id مسرَّب من مستخدم/صف آخر،
        -- ويُرفض إعادة استخدام نفس operation_id مع عملية مختلفة.
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

                -- نفس operation_id موجود لكن بتوقيع مختلف (مستخدم/صف/عملية أخرى)
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

        -- جداول محظورة نهائياً: لا يجوز لأي دور مزامنتها عبر RPC
        IF v_table_name IN ('users', 'farms') THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'status', 'error',
                'message', 'جدول ممنوع للمزامنة عبر RPC: ' || v_table_name
            );
            CONTINUE;
        END IF;

        -- Role-based whitelist: مصفوفة صلاحيات مركزية واحدة عبر sync_can_write.
        -- تُحلّ محل الـ NOT IN المبعثرة السابقة لكل دور على حدة.
        -- P0: العامل لا يصلح إلا الجداول التشغيلية (يستبعد customers/flocks/المالية).
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

        -- P0: ملكية السجل — العامل لا يعدّل/يحذف إلا سجلاته هو.
        -- (المدير/المشرف غير مقيدين بالملكية ضمن المزرعة).
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

        -- P0/2: مصفوفة صلاحيات موحدة مع RLS — الحذف للمدير فقط في كل الطبقات.
        -- (RLS: op_delete → current_user_role()='manager'؛ وهنا مثلها تماماً)
        IF v_operation = 'delete' AND v_user_role <> 'manager' THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'status', 'error',
                'message', 'غير مصرح: الحذف للمدير فقط'
            );
            CONTINUE;
        END IF;

        -- column whitelist لكل جدول
        CASE v_table_name
            WHEN 'egg_production' THEN v_allowed_cols := ARRAY['flock_id','date','cartons','trays','loose_eggs','broken_eggs','dirty_eggs','tray_weight_kg','section_no','worker_id'];
            WHEN 'mortality' THEN v_allowed_cols := ARRAY['flock_id','date','count','reason','reason_other','notes','image_url','worker_id','section_no'];
            WHEN 'feed_consumption' THEN v_allowed_cols := ARRAY['flock_id','date','entry_mode','bags_count','quantity_kg','worker_id','section_no'];
            WHEN 'feed_received' THEN v_allowed_cols := ARRAY['date','entry_mode','quantity','quantity_kg','feed_type','supplier','invoice_number','notes','price_per_kg','section_no','worker_id'];
            WHEN 'egg_dispatch' THEN v_allowed_cols := ARRAY['date','customer_id','cartons','trays','tray_weight_kg','notes','payment_status','worker_id'];
            WHEN 'medications' THEN v_allowed_cols := ARRAY['flock_id','date','type','medicine_name','dosage','administration_route','treatment_days','withdrawal_days','notes','worker_id'];
            WHEN 'customers' THEN v_allowed_cols := ARRAY['name','phone','notes'];
            WHEN 'flocks' THEN v_allowed_cols := ARRAY['breed','start_date','initial_count','status','sections_count'];
            WHEN 'expenses' THEN v_allowed_cols := ARRAY['date','category','description','amount'];
            WHEN 'inventory_items' THEN v_allowed_cols := ARRAY['name','unit','low_stock_threshold','notes'];
            WHEN 'inventory_transactions' THEN v_allowed_cols := ARRAY['item_id','date','type','quantity','note','user_id'];
            WHEN 'opening_balances' THEN v_allowed_cols := ARRAY['flock_id','eggs_produced','eggs_dispatched','feed_consumed_kg','initial_birds','mortality_count','total_payments','total_revenues','sections'];
            WHEN 'payments' THEN v_allowed_cols := ARRAY['dispatch_id','customer_id','date','price_per_carton','total_due','amount_paid','payment_method','due_date','notes','manager_id'];
            ELSE v_allowed_cols := ARRAY[]::text[];
        END CASE;

        -- P0: منع العامل/المشرف من تعديل الأعمدة الحسّاسة (مالية/أسعار/حالة محاسبية)
        -- حتى في الجداول التشغيلية. وكذلك منع تغيير ملكية السجل (worker_id).
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

        -- P0/1: التكامل المرجعي عبر المزرعة — أي عمود علني (foreign key) في الحمولة
        -- يجب أن يشير لصف داخل نفس مزرعة المستخدم، وإلا Rفضٌ صريح.
        -- لا نعتمد على FK وحده (الوجود لا يعني نفس المزرعة).
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

            IF v_table_name IN ('egg_production', 'mortality', 'feed_consumption', 'medications', 'opening_balances')
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
                    -- P0: العامل/المشرف لا يُدخل worker_id من الحمولة — يُلزمان بهويتهما لاحقاً
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
                -- P0/3: حذف ناعم مع OCC — يتطلب previous_version مطابقاً،
                -- ويُعتبر تعارضاً (conflict) عندما لا يتطابق (ROW_COUNT = 0).
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

            -- P0: تسجيل التغيير في sync_changes ليراه الأجهزة الأخرى عبر pull.
            -- يحل مشكلة: sync_records_batch كان يكتب مباشرة بدون trigger
            -- (لأنه قام بتعطيله)، فلم يُسجَّل أي تغيير في sync_changes.
            DECLARE
                v_sc_record jsonb;
                v_sc_payload jsonb;
            BEGIN
                -- قراءة الصف بعد التعديل (يفعل INSERT/UPDATE/DELETE الناعم)
                EXECUTE format(
                    'SELECT to_jsonb(t) FROM %I t WHERE t.id = $1 AND t.farm_id = $2',
                    v_table_name
                ) INTO v_sc_record
                USING v_record_id, v_user_farm;

                IF v_sc_record IS NOT NULL THEN
                    -- إزالة sync_status و deleted_at فقط (نحتفظ بـ version لصحة OCC)
                    v_sc_payload := v_sc_record - 'sync_status' - 'deleted_at';
                ELSE
                    v_sc_payload := jsonb_build_object('id', v_record_id);
                END IF;

                INSERT INTO sync_changes (table_name, record_id, operation, farm_id, user_id, payload)
                VALUES (v_table_name, v_record_id, upper(v_operation), v_user_farm, auth.uid(), v_sc_payload);
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

                -- حفظ في سجل الـ idempotency
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
$$;

GRANT EXECUTE ON FUNCTION public.sync_records_batch(jsonb) TO authenticated;

-- ============================================================
-- 5) pull_remote_changes — نسخة مُعاد كتابتها تستخدم sync_can_read
--    بدلاً من NOT IN ('payments','expenses') الثابتة.
-- ============================================================
CREATE OR REPLACE FUNCTION public.pull_remote_changes(
    p_farm_id uuid,
    p_from_version bigint DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role     text;
    v_latest   bigint;
    v_min_keep bigint;
    v_changes  jsonb;
    v_cp       record;
    v_operational_only boolean := false;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: غير مسجل الدخول';
    END IF;

    -- السماح: system_admin (كل المداجن) أو manager/worker لمزرعته.
    -- العامل يسحب البيانات التشغيلية فقط (يُستبعد الجدولان الماليان).
    IF NOT public.is_system_admin() THEN
        SELECT public.current_user_role() INTO v_role;
        IF v_role NOT IN ('manager', 'worker') THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: دور غير مصرح بسحب المزامنة';
        END IF;
        -- إجبار p_farm_id على مزرعة المستخدم؛ تجاهل أي قيمة أخرى من العميل.
        IF p_farm_id IS DISTINCT FROM public.current_user_farm_id() THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: مزرعة غير مصرح بها';
        END IF;
        -- العامل: الوصول التشغيلي فقط (لا يطّلع على المالية: payments/expenses).
        IF v_role = 'worker' THEN
            v_operational_only := true;
        END IF;
    END IF;

    -- صيانة دورية مقيّدة زمنياً (retention + compaction + checkpoint) —
    -- تُنفَّذ كحد أقصى مرة كل maintenance_interval_minutes، فلا تكلّف السحب.
    PERFORM public.auto_maintain_sync();

    -- قراءة watermark من checkpoint (بدل فحوص MIN/MAX المكلفة في كل سحب).
    -- إذا لم يوجد checkpoint بعد (مزرعة جديدة/أول سحب)، نحسب ونخزّن.
    SELECT latest_version, purged_below INTO v_latest, v_min_keep
    FROM sync_checkpoint WHERE farm_id = p_farm_id;

    IF v_latest IS NULL THEN
        SELECT COALESCE(MAX(server_version), 0), COALESCE(MIN(server_version), 0)
            INTO v_latest, v_min_keep
        FROM sync_changes WHERE farm_id = p_farm_id;
        IF v_min_keep = 0 THEN v_min_keep := v_latest; END IF;
        INSERT INTO sync_checkpoint (farm_id, latest_version, purged_below, updated_at)
        VALUES (p_farm_id, v_latest, v_min_keep, NOW())
        ON CONFLICT (farm_id) DO UPDATE SET
            latest_version = EXCLUDED.latest_version,
            purged_below   = EXCLUDED.purged_below,
            updated_at     = NOW();
    END IF;

    -- جلب التغييرات الأحدث من الإصدار المطلوب.
    -- للعامل: نستبعد الجداول المالية ونعيد watermark فرعي للعمليات التشغيلية
    -- حتى لا يخزّن جهاز العامل watermark يتجاوز تغييراته المسموح بها.
    IF v_operational_only THEN
        SELECT jsonb_agg(jsonb_build_object(
            'table_name', sc.table_name,
            'record_id', sc.record_id,
            'operation', sc.operation,
            'payload', CASE
                -- P0 أمنّي: إخفاء الحقول الحسّاسة عن العامل حتى داخل الجداول المسموحة
                WHEN sc.table_name = 'egg_dispatch' THEN sc.payload - 'payment_status'
                ELSE sc.payload
            END,
            'server_version', sc.server_version,
            'created_at', sc.created_at
        )) INTO v_changes
        FROM sync_changes sc
        WHERE sc.farm_id = p_farm_id
          AND public.sync_can_read('worker', sc.table_name)
          AND sc.server_version > p_from_version
        ORDER BY sc.server_version ASC;

        -- watermark العامل = أعلى نسخة تشغيلية أعيدت له (باستثناء المالية).
        SELECT COALESCE(MAX(server_version), p_from_version) INTO v_latest
        FROM sync_changes
        WHERE farm_id = p_farm_id
          AND public.sync_can_read('worker', table_name)
          AND server_version > p_from_version;

        -- أقل نسخة تشغيلية محفوظة بعد الضغط/الاحتفاظ (لمعرفة ما إذا تأخر الجهاز).
        SELECT COALESCE(MIN(server_version), v_latest) INTO v_min_keep
        FROM sync_changes
        WHERE farm_id = p_farm_id
          AND public.sync_can_read('worker', table_name);
    ELSE
        SELECT jsonb_agg(jsonb_build_object(
            'table_name', sc.table_name,
            'record_id', sc.record_id,
            'operation', sc.operation,
            'payload', sc.payload,
            'server_version', sc.server_version,
            'created_at', sc.created_at
        )) INTO v_changes
        FROM sync_changes sc
        WHERE sc.farm_id = p_farm_id
          AND sc.server_version > p_from_version
        ORDER BY sc.server_version ASC;
    END IF;

    -- إذا كان الجهاز متأخراً عن أقل نسخة محفوظة، لا يمكنه تطبيق delta ناقص
    IF p_from_version > 0 AND p_from_version < v_min_keep THEN
        RETURN jsonb_build_object(
            'resync_required', true,
            'message', 'بيانات الجهاز أقدم من فترة الاحتفاظ، يلزم إعادة مزامنة كاملة',
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

