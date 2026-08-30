-- ============================================================
-- Sync Protocol V3: إضافة عمود status وتتبع الحالة
-- ============================================================
-- هذا الملف يصلح الفجوة بين sync_changes و sync_queue
-- ويضيف عمود status لتتبع حالة المزامنة (pending/synced/failed)
-- ============================================================

-- 1. إضافة عمود status إذا لم يكن موجوداً
ALTER TABLE public.sync_changes 
ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'pending';

-- 2. إضافة فهرس لتحسين الأداء
CREATE INDEX IF NOT EXISTS idx_sync_changes_status_pending 
ON public.sync_changes(farm_id, status) 
WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_sync_changes_changed_at 
ON public.sync_changes(changed_at DESC);

-- 3. تحديث دالة sync_records_batch لدعم status
DROP FUNCTION IF EXISTS public.sync_records_batch(JSONB, UUID);

CREATE OR REPLACE FUNCTION public.sync_records_batch(
    p_records JSONB,
    p_user_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid UUID;
    v_farm_id UUID;
    v_role TEXT;
    v_record JSONB;
    v_table TEXT;
    v_action TEXT;
    v_data JSONB;
    v_record_id UUID;
    v_payload_farm_id UUID;
    v_client_updated_at TIMESTAMPTZ;
    v_existing_updated_at TIMESTAMPTZ;
    v_existing JSONB;
    v_success JSONB := '[]'::JSONB;
    v_failed JSONB := '[]'::JSONB;
    v_conflicts JSONB := '[]'::JSONB;
    v_count INTEGER := 0;
    v_max_batch INTEGER := 100;
BEGIN
    -- Authentication: Trust ONLY JWT user.id
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: Invalid JWT';
    END IF;

    -- Reject if client sends a different user_id
    IF p_user_id IS NOT NULL AND p_user_id <> v_uid THEN
        RAISE EXCEPTION 'Security Violation: user_id mismatch';
    END IF;

    -- Get User Context
    SELECT u.farm_id, u.role INTO v_farm_id, v_role
    FROM public.users u WHERE u.id = v_uid;

    IF v_farm_id IS NULL THEN
        RAISE EXCEPTION 'User not assigned to any farm';
    END IF;

    -- Validate Input
    IF jsonb_typeof(p_records) <> 'array' THEN
        RAISE EXCEPTION 'p_records must be a JSON array';
    END IF;

    IF jsonb_array_length(p_records) > v_max_batch THEN
        RAISE EXCEPTION 'Batch too large (max %)', v_max_batch;
    END IF;

    -- Process Each Record
    FOR v_record IN SELECT value FROM jsonb_array_elements(p_records) LOOP
        BEGIN
            v_count := v_count + 1;

            v_table := lower(trim(v_record ->> 'table'));
            v_action := upper(COALESCE(NULLIF(trim(v_record ->> 'action'), ''), 'INSERT'));
            v_data := COALESCE(v_record -> 'data', '{}'::JSONB);

            -- Validate Table & Action
            IF v_table IS NULL OR v_table = '' THEN
                RAISE EXCEPTION 'Missing table name';
            END IF;

            IF v_action NOT IN ('INSERT', 'UPDATE', 'DELETE') THEN
                RAISE EXCEPTION 'Invalid action: %', v_action;
            END IF;

            -- Allowed Tables List
            IF v_table NOT IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications',
                'customers', 'payments', 'expenses', 'flocks',
                'inventory_items', 'inventory_transactions'
            ) THEN
                RAISE EXCEPTION 'Table not allowed for sync: %', v_table;
            END IF;

            -- Extract ID and Farm from Payload
            v_record_id := (v_data ->> 'id')::UUID;
            v_payload_farm_id := (v_data ->> 'farm_id')::UUID;

            IF v_record_id IS NULL THEN
                -- Generate new ID for INSERT
                IF v_action = 'INSERT' THEN
                    v_record_id := gen_random_uuid();
                    v_data := jsonb_insert(v_data, '{id}', to_jsonb(v_record_id));
                ELSE
                    RAISE EXCEPTION 'Missing record id for UPDATE/DELETE';
                END IF;
            END IF;

            -- Validate Farm Ownership
            IF v_payload_farm_id IS NOT NULL AND v_payload_farm_id <> v_farm_id THEN
                RAISE EXCEPTION 'Farm mismatch: trying to write to farm %', v_payload_farm_id;
            END IF;

            -- Add farm_id if missing
            IF v_data ->> 'farm_id' IS NULL THEN
                v_data := jsonb_insert(v_data, '{farm_id}', to_jsonb(v_farm_id));
            END IF;

            -- Add updated_at
            v_client_updated_at := (v_data ->> 'updated_at')::TIMESTAMPTZ;
            IF v_client_updated_at IS NULL THEN
                v_client_updated_at := NOW();
                v_data := jsonb_insert(v_data, '{updated_at}', to_jsonb(v_client_updated_at));
            END IF;

            -- Check for Conflicts (Last Write Wins)
            EXECUTE format(
                'SELECT updated_at FROM public.%I WHERE id = $1',
                v_table
            ) USING v_record_id INTO v_existing_updated_at;

            IF v_existing_updated_at IS NOT NULL 
               AND v_existing_updated_at > v_client_updated_at THEN
                -- Conflict: Server has newer data
                v_conflicts := v_conflicts || jsonb_build_array(
                    jsonb_build_object(
                        'id', v_record_id,
                        'table', v_table,
                        'status', 'conflict',
                        'reason', 'server_newer',
                        'server_updated_at', v_existing_updated_at
                    )
                );
                CONTINUE;
            END IF;

            -- Execute Operation
            IF v_action = 'DELETE' THEN
                -- Soft Delete
                EXECUTE format(
                    'UPDATE public.%I SET deleted_at = NOW(), updated_at = $2 WHERE id = $1',
                    v_table
                ) USING v_record_id, NOW();

                -- Log to sync_changes
                INSERT INTO public.sync_changes (
                    table_name, record_id, operation, farm_id, 
                    user_id, payload, client_updated_at, status
                ) VALUES (
                    v_table, v_record_id, 'DELETE', v_farm_id,
                    v_uid, v_data, v_client_updated_at, 'synced'
                );

                v_success := v_success || jsonb_build_array(
                    jsonb_build_object('id', v_record_id, 'table', v_table, 'action', 'DELETE', 'status', 'synced')
                );

            ELSIF v_action = 'INSERT' THEN
                -- Check if exists
                EXECUTE format(
                    'SELECT 1 FROM public.%I WHERE id = $1',
                    v_table
                ) USING v_record_id INTO v_existing;

                IF v_existing IS NOT NULL THEN
                    -- Convert to UPDATE
                    EXECUTE format(
                        'UPDATE public.%I SET %s WHERE id = $%s',
                        v_table,
                        (SELECT string_agg(format('%I = $%s', key, row_number() over() + 1), ', ')
                         FROM jsonb_object_keys(v_data)),
                        (SELECT count(*) + 1 FROM jsonb_object_keys(v_data))
                    ) USING v_record_id, VARIADIC ARRAY(SELECT value FROM jsonb_each_text(v_data));
                ELSE
                    -- Real INSERT
                    EXECUTE format(
                        'INSERT INTO public.%I (%s) VALUES (%s)',
                        v_table,
                        (SELECT string_agg(key, ', ') FROM jsonb_object_keys(v_data)),
                        (SELECT string_agg('$' || (row_number() over()), ', ') FROM jsonb_object_keys(v_data))
                    ) USING VARIADIC ARRAY(SELECT value FROM jsonb_each_text(v_data));
                END IF;

                -- Log to sync_changes
                INSERT INTO public.sync_changes (
                    table_name, record_id, operation, farm_id,
                    user_id, payload, client_updated_at, status
                ) VALUES (
                    v_table, v_record_id, v_action, v_farm_id,
                    v_uid, v_data, v_client_updated_at, 'synced'
                );

                v_success := v_success || jsonb_build_array(
                    jsonb_build_object('id', v_record_id, 'table', v_table, 'action', v_action, 'status', 'synced')
                );

            ELSIF v_action = 'UPDATE' THEN
                EXECUTE format(
                    'UPDATE public.%I SET %s WHERE id = $1',
                    v_table,
                    (SELECT string_agg(format('%I = $%s', key, row_number() over() + 1), ', ')
                     FROM jsonb_object_keys(v_data))
                ) USING v_record_id, VARIADIC ARRAY(SELECT value FROM jsonb_each_text(v_data));

                -- Log to sync_changes
                INSERT INTO public.sync_changes (
                    table_name, record_id, operation, farm_id,
                    user_id, payload, client_updated_at, status
                ) VALUES (
                    v_table, v_record_id, v_action, v_farm_id,
                    v_uid, v_data, v_client_updated_at, 'synced'
                );

                v_success := v_success || jsonb_build_array(
                    jsonb_build_object('id', v_record_id, 'table', v_table, 'action', v_action, 'status', 'synced')
                );
            END IF;

        EXCEPTION WHEN OTHERS THEN
            v_failed := v_failed || jsonb_build_array(
                jsonb_build_object(
                    'id', COALESCE(v_record_id, v_data ->> 'id'),
                    'table', v_table,
                    'status', 'failed',
                    'error', SQLERRM
                )
            );
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'success_records', v_success,
        'failed_records', v_failed,
        'conflict_records', v_conflicts,
        'total_processed', v_count
    );
END;
$$;

-- 4. منح الصلاحيات
REVOKE ALL ON FUNCTION public.sync_records_batch(JSONB, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_records_batch(JSONB, UUID) TO authenticated;

COMMENT ON FUNCTION public.sync_records_batch IS 'Processes batch sync records with status tracking (V3)';

-- 5. دالة جلب السجلات المعلقة للموبايل
CREATE OR REPLACE FUNCTION public.get_pending_sync_changes(p_limit INTEGER DEFAULT 50)
RETURNS TABLE (
    id BIGINT,
    farm_id UUID,
    table_name TEXT,
    record_id UUID,
    operation TEXT,
    changed_at TIMESTAMPTZ,
    user_id UUID,
    payload JSONB,
    server_version BIGINT
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN QUERY
    SELECT 
        sc.id::BIGINT,
        sc.farm_id,
        sc.table_name,
        sc.record_id,
        sc.operation,
        sc.changed_at,
        sc.user_id,
        sc.payload,
        sc.server_version
    FROM public.sync_changes sc
    WHERE sc.status = 'pending'
      AND sc.farm_id = current_user_farm_id()
    ORDER BY sc.server_version ASC
    LIMIT p_limit;
END;
$$;

-- 6. دالة تحديث حالة المزامنة
CREATE OR REPLACE FUNCTION public.mark_sync_records_as_synced(p_ids BIGINT[])
RETURNS VOID AS $$
BEGIN
    UPDATE public.sync_changes
    SET status = 'synced',
        changed_at = NOW()
    WHERE id = ANY(p_ids)
      AND farm_id = current_user_farm_id();
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Failed to update sync status: %', SQLERRM;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. دالة تنظيف السجلات القديمة
CREATE OR REPLACE FUNCTION public.cleanup_old_sync_logs(days_to_keep INTEGER DEFAULT 30)
RETURNS BIGINT AS $$
DECLARE
    deleted_count BIGINT;
BEGIN
    DELETE FROM public.sync_changes
    WHERE status = 'synced'
      AND changed_at < NOW() - (days_to_keep || ' days')::INTERVAL;
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 8. سياسات الأمان لـ sync_changes
DROP POLICY IF EXISTS "sync_changes_select" ON public.sync_changes;
CREATE POLICY "sync_changes_select" ON public.sync_changes
FOR SELECT TO authenticated
USING (farm_id = current_user_farm_id());

DROP POLICY IF EXISTS "sync_changes_no_manual_modification" ON public.sync_changes;
CREATE POLICY "sync_changes_no_manual_modification" ON public.sync_changes
FOR ALL TO authenticated
USING (false)
WITH CHECK (false);
