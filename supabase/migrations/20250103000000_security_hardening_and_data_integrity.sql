-- ============================================================
-- SECURITY HARDENING & DATA INTEGRITY FIXES
-- تاريخ: 2025-01-03
-- الوصف: إصلاح ثغرات أمنية حرجة، تحسين سلامة البيانات، وتوحيد عقد المزامنة
-- ============================================================

-- 1. إصلاح ثغرة p_user_id في دالة المزامنة
-- منع تمرير user_id مزور وفرض استخدام auth.uid()
CREATE OR REPLACE FUNCTION public.sync_records_batch_v2(
    p_records JSONB,
    p_client_timestamp TIMESTAMPTZ DEFAULT NOW()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER -- مهم: يعمل بصلاحيات المدير للتحقق من القيود
AS $$
DECLARE
    v_record JSONB;
    v_table_name TEXT;
    v_operation TEXT;
    v_record_id UUID;
    v_payload JSONB;
    v_farm_id UUID;
    v_user_id UUID;
    v_role TEXT;
    v_result JSONB := '{"success": [], "failed": [], "conflicts": []}';
    v_error_message TEXT;
    v_flock_belongs BOOLEAN;
    v_worker_belongs BOOLEAN;
    v_customer_belongs BOOLEAN;
BEGIN
    -- الحصول على هوية المستخدم الحقيقي من JWT فقط (إصلاح الثغرة الأمنية)
    v_user_id := auth.uid();
    
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: Invalid or missing user token';
    END IF;

    -- جلب بيانات المستخدم والمزرعة والدور
    SELECT u.farm_id, u.role INTO v_farm_id, v_role
    FROM public.users u
    WHERE u.id = v_user_id;

    IF v_farm_id IS NULL THEN
        RAISE EXCEPTION 'User profile not found or not associated with any farm';
    END IF;

    -- التحقق من الصلاحيات للعمليات الحساسة
    -- العمال لا يمكنهم مزامنة جداول مالية
    FOR v_record IN SELECT * FROM jsonb_array_elements(p_records)
    LOOP
        v_table_name := v_record->>'table_name';
        v_operation := v_record->>'operation';
        v_record_id := (v_record->>'record_id')::UUID;
        v_payload := v_record->'payload';

        -- منع العمال من مزامنة البيانات المالية مباشرة
        IF v_role = 'worker' AND v_table_name IN ('payments', 'expenses', 'egg_dispatch') THEN
            -- استثناء: السماح بـ egg_dispatch إذا لم يحتوي على بيانات مالية في payload
            IF v_table_name = 'egg_dispatch' THEN
                IF v_payload ? 'price_per_carton' OR v_payload ? 'total_amount' THEN
                    v_result := jsonb_set(v_result, '{failed}', 
                        jsonb_array_append(v_result->'failed', jsonb_build_object(
                            'id', v_record_id, 
                            'error', 'Workers cannot sync financial data'
                        )));
                    CONTINUE;
                END IF;
            ELSE
                v_result := jsonb_set(v_result, '{failed}', 
                    jsonb_array_append(v_result->'failed', jsonb_build_object(
                        'id', v_record_id, 
                        'error', 'Access denied to financial tables'
                    )));
                CONTINUE;
            END IF;
        END IF;

        -- التحقق من سلامة العلاقات (Tenant Isolation)
        -- التأكد أن الكيانات المرتبطة تنتمي لنفس المزرعة
        IF v_payload ? 'flock_id' THEN
            SELECT EXISTS (
                SELECT 1 FROM flocks WHERE id = (v_payload->>'flock_id')::UUID AND farm_id = v_farm_id
            ) INTO v_flock_belongs;
            
            IF NOT v_flock_belongs THEN
                v_result := jsonb_set(v_result, '{failed}', 
                    jsonb_array_append(v_result->'failed', jsonb_build_object(
                        'id', v_record_id, 
                        'error', 'Invalid flock_id: Does not belong to your farm'
                    )));
                CONTINUE;
            END IF;
        END IF;

        IF v_payload ? 'worker_id' THEN
            -- العامل لا يمكنه التظاهر بشخص آخر
            IF v_role = 'worker' AND (v_payload->>'worker_id')::UUID != v_user_id THEN
                 v_result := jsonb_set(v_result, '{failed}', 
                    jsonb_array_append(v_result->'failed', jsonb_build_object(
                        'id', v_record_id, 
                        'error', 'Cannot impersonate another worker'
                    )));
                CONTINUE;
            END IF;
            
            -- التحقق العام من انتماء العامل للمزرعة
            SELECT EXISTS (
                SELECT 1 FROM users WHERE id = (v_payload->>'worker_id')::UUID AND farm_id = v_farm_id
            ) INTO v_worker_belongs;

            IF NOT v_worker_belongs THEN
                v_result := jsonb_set(v_result, '{failed}', 
                    jsonb_array_append(v_result->'failed', jsonb_build_object(
                        'id', v_record_id, 
                        'error', 'Invalid worker_id: Does not belong to your farm'
                    )));
                CONTINUE;
            END IF;
        END IF;

        IF v_payload ? 'customer_id' THEN
            SELECT EXISTS (
                SELECT 1 FROM customers WHERE id = (v_payload->>'customer_id')::UUID AND farm_id = v_farm_id
            ) INTO v_customer_belongs;

            IF NOT v_customer_belongs THEN
                v_result := jsonb_set(v_result, '{failed}', 
                    jsonb_array_append(v_result->'failed', jsonb_build_object(
                        'id', v_record_id, 
                        'error', 'Invalid customer_id: Does not belong to your farm'
                    )));
                CONTINUE;
            END IF;
        END IF;

        -- تنفيذ العملية بناءً على النوع
        BEGIN
            IF v_operation = 'INSERT' THEN
                -- معالجة خاصة للنفوق لمنع الرصيد السلبي
                IF v_table_name = 'mortality' THEN
                    DECLARE
                        v_flock_id UUID := (v_payload->>'flock_id')::UUID;
                        v_count INTEGER := (v_payload->>'count')::INTEGER;
                        v_current_count INTEGER;
                    BEGIN
                        SELECT current_count INTO v_current_count FROM flocks WHERE id = v_flock_id;
                        IF v_current_count < v_count THEN
                            RAISE EXCEPTION 'Mortality count (%) exceeds current flock size (%)', v_count, v_current_count;
                        END IF;
                    END;
                END IF;

                EXECUTE format('INSERT INTO public.%I (id, farm_id, %s, created_at, updated_at) VALUES (%L, %L, %s, NOW(), NOW())',
                    v_table_name,
                    (SELECT string_agg(key, ', ') FROM jsonb_object_keys(v_payload) key),
                    v_record_id,
                    v_farm_id,
                    (SELECT string_agg(format('%L', value), ', ') FROM jsonb_each_text(v_payload) val(key, value))
                );
                
                v_result := jsonb_set(v_result, '{success}', jsonb_array_append(v_result->'success', to_jsonb(v_record_id)));

            ELSIF v_operation = 'UPDATE' THEN
                EXECUTE format('UPDATE public.%I SET %s, updated_at = NOW() WHERE id = %L AND farm_id = %L',
                    v_table_name,
                    (SELECT string_agg(format('%I = %L', key, value), ', ') FROM jsonb_each_text(v_payload) key(key, value)),
                    v_record_id,
                    v_farm_id
                );
                
                v_result := jsonb_set(v_result, '{success}', jsonb_array_append(v_result->'success', to_jsonb(v_record_id)));

            ELSIF v_operation = 'DELETE' THEN
                -- المدير فقط يمكنه الحذف
                IF v_role != 'manager' THEN
                     v_result := jsonb_set(v_result, '{failed}', 
                        jsonb_array_append(v_result->'failed', jsonb_build_object(
                            'id', v_record_id, 
                            'error', 'Only managers can delete records'
                        )));
                    CONTINUE;
                END IF;

                EXECUTE format('DELETE FROM public.%I WHERE id = %L AND farm_id = %L',
                    v_table_name, v_record_id, v_farm_id
                );
                v_result := jsonb_set(v_result, '{success}', jsonb_array_append(v_result->'success', to_jsonb(v_record_id)));
            END IF;

        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_error_message = MESSAGE_TEXT;
            v_result := jsonb_set(v_result, '{failed}', 
                jsonb_array_append(v_result->'failed', jsonb_build_object(
                    'id', v_record_id, 
                    'error', v_error_message
                )));
        END;
    END LOOP;

    RETURN v_result;
END;
$$;

-- 2. تأمين جدول Audit Log
-- منع أي تعديل أو حذف لسجلات التدقيق حتى من قبل المدير
DROP POLICY IF EXISTS "audit_log_manager" ON public.audit_log;
CREATE POLICY "audit_log_read_only_for_users" ON public.audit_log
    FOR SELECT TO authenticated
    USING (farm_id = current_user_farm_id());

-- السماح فقط للنظام (عبر SECURITY DEFINER) بالإدراج
DROP POLICY IF EXISTS "audit_log_insert" ON public.audit_log;
CREATE POLICY "audit_log_system_insert" ON public.audit_log
    FOR INSERT TO authenticated
    WITH CHECK (false); -- يمنع الإدخال المباشر من المستخدمين، يتم عبر Trigger

-- تأكد من أن الـ Trigger هو الوحيد الذي يضيف سجلات
-- (الـ Trigger الموجود أصلاً سيستمر في العمل)

-- 3. تفعيل RLS لجدول medicines_catalog إذا لم يكن مفعلًا
ALTER TABLE public.medicines_catalog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "catalog_select" ON public.medicines_catalog;
DROP POLICY IF EXISTS "catalog_manager" ON public.medicines_catalog;

CREATE POLICY "medicines_catalog_select" ON public.medicines_catalog
    FOR SELECT TO authenticated
    USING (true); -- قائمة أدوية عامة للجميع

CREATE POLICY "medicines_catalog_modification" ON public.medicines_catalog
    FOR ALL TO authenticated
    USING (current_user_role() = 'manager')
    WITH CHECK (current_user_role() = 'manager');

-- 4. إضافة قيود CHECK لمنع الرصيد السلبي في القطعان
-- ملاحظة: قد تفشل إذا كانت هناك بيانات سلبية موجودة مسبقاً، يجب تنظيفها أولاً
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'flocks_non_negative_count'
    ) THEN
        ALTER TABLE public.flocks
        ADD CONSTRAINT flocks_non_negative_count CHECK (current_count >= 0);
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not add non-negative constraint due to existing negative data. Please clean data first.';
END $$;

-- 5. توحيد هيكل جدول sync_changes (إضافة حقول مفقودة إذا لزم الأمر)
-- التأكد من وجود الأعمدة المطلوبة للعقد الموحد
ALTER TABLE public.sync_changes
ADD COLUMN IF NOT EXISTS server_version BIGINT DEFAULT 0;

-- إنشاء فهرس لتحسين أداء الاستعلامات المعلقة
CREATE INDEX IF NOT EXISTS idx_sync_changes_status_pending_v2
ON public.sync_changes (farm_id, status, changed_at)
WHERE status = 'pending';

-- 6. تقييد صلاحيات تنفيذ الدوال الحساسة
REVOKE EXECUTE ON FUNCTION public.cleanup_old_sync_logs(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cleanup_old_sync_logs(INTEGER) TO service_role;
-- يمكن للمدير استدعاؤها عبر واجهة برمجية آمنة فقط

COMMENT ON FUNCTION public.sync_records_batch_v2 IS 'Secure batch sync function with strict tenant isolation and role checks. v_user_id is forced from auth.uid().';
