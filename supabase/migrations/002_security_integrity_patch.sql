-- ============================================================
-- Migration: 002_security_integrity_patch.sql
-- وصف: إصلاح ثغرات أمنية حرجة، توحيد المزامنة، وضمان سلامة البيانات
-- التاريخ: 2024-05-21
-- الحالة: CRITICAL PATCH
-- ============================================================

-- 1. إصلاح دالة المزامنة sync_records_batch (النقاط 2, 3, 9, 10, 11, 12)
-- إعادة إنشاء الدالة بمنطق أمني صارم وعقد موحد
CREATE OR REPLACE FUNCTION public.sync_records_batch(
    p_records JSONB,
    p_user_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_record JSONB;
    v_table_name TEXT;
    v_operation TEXT;
    v_record_id UUID;
    v_payload JSONB;
    v_farm_id UUID;
    v_user_role TEXT;
    v_current_count INT;
    v_mortality_count INT;
    v_result JSONB := '{"success": [], "failed": [], "conflicts": []}';
    v_error_msg TEXT;
BEGIN
    -- 1. التحقق الأمني الصارم من الهوية (النقطة 3)
    -- تجاهل p_user_id تماماً والاعتماد فقط على JWT
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: No user authenticated';
    END IF;

    -- جلب بيانات المستخدم الحالي من الجلسة الآمنة
    SELECT u.role, u.farm_id 
    INTO v_user_role, v_farm_id
    FROM public.users u
    WHERE u.id = auth.uid();

    IF v_farm_id IS NULL THEN
        RAISE EXCEPTION 'User profile incomplete: No farm assigned';
    END IF;

    -- 2. حلقة المعالجة
    FOR v_record IN SELECT * FROM jsonb_array_elements(p_records)
    LOOP
        BEGIN
            -- توحيد أسماء الحقول (النقطة 2)
            v_table_name := v_record->>'table_name';
            v_operation := v_record->>'operation';
            v_record_id := (v_record->>'record_id')::UUID;
            v_payload := v_record->'payload';

            -- 3. التحقق من تبعية المزرعة للنطاقات الحرجة (النقاط 9, 10)
            -- التأكد أن flock_id أو worker_id في payload يتبعان مزرعة المستخدم
            IF v_payload ? 'flock_id' THEN
                DECLARE v_payload_flock_id UUID := (v_payload->>'flock_id')::UUID;
                BEGIN
                    SELECT farm_id INTO v_farm_id 
                    FROM flocks WHERE id = v_payload_flock_id;
                    
                    IF v_farm_id IS NULL OR v_farm_id != (SELECT farm_id FROM users WHERE id = auth.uid()) THEN
                        RAISE EXCEPTION 'Security Violation: Flock does not belong to your farm';
                    END IF;
                EXCEPTION WHEN OTHERS THEN
                    RAISE EXCEPTION 'Invalid flock_id provided';
                END;
            END IF;

            IF v_payload ? 'worker_id' THEN
                DECLARE v_payload_worker_id UUID := (v_payload->>'worker_id')::UUID;
                BEGIN
                    -- العامل لا يمكنه التظاهر بشخص آخر
                    IF v_payload_worker_id != auth.uid() AND v_user_role != 'manager' THEN
                         RAISE EXCEPTION 'Security Violation: Cannot record on behalf of another worker';
                    END IF;
                    
                    SELECT farm_id INTO v_farm_id 
                    FROM users WHERE id = v_payload_worker_id;
                    
                    IF v_farm_id IS NULL OR v_farm_id != (SELECT farm_id FROM users WHERE id = auth.uid()) THEN
                        RAISE EXCEPTION 'Security Violation: Worker does not belong to your farm';
                    END IF;
                EXCEPTION WHEN OTHERS THEN
                    RAISE EXCEPTION 'Invalid worker_id provided';
                END;
            END IF;

            -- 4. معالجة العمليات حسب الجدول
            IF v_table_name = 'mortality' AND v_operation = 'INSERT' THEN
                -- النقطة 11: منع النفوق الذي يتجاوز العدد المتبقي
                v_mortality_count := (v_payload->>'count')::INT;
                
                SELECT current_count INTO v_current_count
                FROM flocks
                WHERE id = (v_payload->>'flock_id')::UUID;

                IF v_current_count IS NULL OR v_current_count < v_mortality_count THEN
                    v_result := v_result || jsonb_build_object('failed', jsonb_build_array(v_record_id || ': Insufficient flock count'));
                    CONTINUE; -- تخطي هذا السجل
                END IF;
            END IF;

            -- تنفيذ الإدخال/التحديث الفعلي (مثال مبسط، يحتاج توسيع لكل الجداول)
            IF v_operation = 'INSERT' THEN
                -- هنا يتم بناء ديناميكي أو حالات لكل جدول
                -- للتبسيط في هذا التصحيح، سنفترض وجود جداول قياسية
                -- في التطبيق الفعلي يجب تفريع logic لكل جدول
                
                INSERT INTO sync_changes (
                    farm_id, table_name, record_id, operation, changed_at, user_id, payload, status
                ) VALUES (
                    v_farm_id, v_table_name, v_record_id, v_operation, NOW(), auth.uid(), v_payload, 'pending'
                );
                
                -- إضافة للسجلات الناجحة
                v_result := v_result || jsonb_build_object('success', jsonb_build_array(v_record_id));
            ELSIF v_operation = 'UPDATE' THEN
                 UPDATE sync_changes
                 SET payload = v_payload, changed_at = NOW(), status = 'pending'
                 WHERE record_id = v_record_id AND farm_id = v_farm_id;
                 
                 v_result := v_result || jsonb_build_object('success', jsonb_build_array(v_record_id));
            END IF;

        EXCEPTION WHEN OTHERS THEN
            v_error_msg := SQLERRM;
            v_result := v_result || jsonb_build_object('failed', jsonb_build_array(v_record_id || ': ' || v_error_msg));
            -- تسجيل الخطأ للتحقيق
            INSERT INTO audit_log (user_id, farm_id, action, table_name, old_values, new_values)
            VALUES (auth.uid(), v_farm_id, 'SYNC_ERROR', v_table_name, NULL, jsonb_build_object('error', v_error_msg, 'payload', v_payload));
        END;
    END LOOP;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. تأمين جدول Audit Log (النقطة 7)
-- جعله للقراءة فقط حتى للمدير، ولا أحد يستطيع التعديل أو الحذف
DROP POLICY IF EXISTS "audit_log_manager_all" ON audit_log;
CREATE POLICY "audit_log_read_only" ON audit_log
FOR SELECT TO authenticated
USING (farm_id = current_user_farm_id());

-- منع أي تعديل أو حذف من أي شخص (حتى المدير)
CREATE POLICY "audit_log_no_modifications" ON audit_log
FOR ALL TO authenticated
USING (false)
WITH CHECK (false);

-- السماح للنظام فقط بالإدراج عبر Security Definer Function مستقبلاً إذا لزم
-- لكن حالياً الإدراج يتم عبر Triggers وهي آمنة لأنها جزء من DB Engine

-- 3. تفعيل RLS لجدول Medicines Catalog (النقطة 6)
ALTER TABLE public.medicines_catalog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "catalog_manager" ON medicines_catalog;
DROP POLICY IF EXISTS "catalog_select" ON medicines_catalog;

-- الجميع يقرأ، المدير فقط يعدل
CREATE POLICY "catalog_public_read" ON medicines_catalog
FOR SELECT TO authenticated
USING (true);

CREATE POLICY "catalog_manager_write" ON medicines_catalog
FOR ALL TO authenticated
USING (current_user_role() = 'manager')
WITH CHECK (current_user_role() = 'manager');

-- 4. إضافة قيود سلامة البيانات (Check Constraints) (النقطة 11)
-- منع عدد الطيور السالب
ALTER TABLE flocks DROP CONSTRAINT IF EXISTS flocks_current_count_check;
ALTER TABLE flocks ADD CONSTRAINT flocks_current_count_check CHECK (current_count >= 0);

-- منع كميات سالبة في الاستهلاك والإنتاج
ALTER TABLE feed_consumption DROP CONSTRAINT IF EXISTS feed_consumption_quantity_check;
ALTER TABLE feed_consumption ADD CONSTRAINT feed_consumption_quantity_check CHECK (quantity_kg >= 0);

ALTER TABLE egg_production DROP CONSTRAINT IF EXISTS egg_production_counts_check;
ALTER TABLE egg_production ADD CONSTRAINT egg_production_counts_check CHECK (
    cartons >= 0 AND trays >= 0 AND loose_eggs >= 0 AND broken_eggs >= 0
);

-- 5. فصل البيانات المالية عن التشغيلية (النقطة 5) - تحضير هيكلي
-- ملاحظة: هذا يتطلب تغييرات كبيرة في الكود، هنا نجهز القاعدة فقط
-- نقوم بإنشاء VIEW للعامل يخفي البيانات المالية من egg_dispatch
DROP VIEW IF EXISTS public.worker_dispatch_view;
CREATE VIEW public.worker_dispatch_view AS
SELECT 
    id, farm_id, flock_id, customer_id, date,
    cartons, trays, loose_eggs, total_eggs,
    notes, created_at
FROM egg_dispatch;
-- العامل سيستخدم هذه الـ View بدلاً من الجدول المباشر إذا لزم الأمر، 
-- أو يتم تطبيق RLS لحجب الأعمدة (Postgres لا يدعم RLS على مستوى الأعمدة بسهولة، لذا الـ View هو الحل)

-- 6. تنظيف الصلاحيات للدوال الخطرة (النقطة 8)
REVOKE EXECUTE ON FUNCTION cleanup_old_sync_logs(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cleanup_old_sync_logs(INTEGER) TO service_role;
-- المدير يمكنه استدعاؤها أيضاً إذا أردنا، لكن الأفضل أن تكون مهمة خلفية فقط
-- GRANT EXECUTE ON FUNCTION cleanup_old_sync_logs(INTEGER) TO authenticated; 

COMMENT ON FUNCTION public.sync_records_batch IS 'Secure sync function enforcing auth.uid() and farm isolation';
