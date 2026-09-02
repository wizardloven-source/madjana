-- ============================================================
-- Migration 20260902_003: Atomic mortality + lock flock_id
-- ============================================================

-- 1) تحديث atomic: حماية current_count من race conditions
CREATE OR REPLACE FUNCTION public.update_flock_count_on_mortality()
RETURNS TRIGGER AS $$
DECLARE
    v_affected INTEGER;
    v_delta INTEGER;
    v_target_flock UUID;
BEGIN
    v_target_flock := COALESCE(NEW.flock_id, OLD.flock_id);
    IF v_target_flock IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    IF TG_OP = 'INSERT' THEN
        -- حماية ذرية: ننقص العدد فقط إذا كان كافياً
        UPDATE flocks
        SET current_count = current_count - NEW.count, updated_at = NOW()
        WHERE id = NEW.flock_id
          AND current_count >= NEW.count;

        GET DIAGNOSTICS v_affected = ROW_COUNT;
        IF v_affected = 0 THEN
            RAISE EXCEPTION 'عدد النفوق (%) يتجاوز العدد الحالي في القطيع', NEW.count;
        END IF;

    ELSIF TG_OP = 'UPDATE' THEN
        -- حماية flock_id من التعديل بعد الإنشاء
        IF NEW.flock_id IS DISTINCT FROM OLD.flock_id THEN
            RAISE EXCEPTION 'لا يمكن تغيير القطيع بعد إنشاء سجل النفوق';
        END IF;

        -- soft delete: استرجاع العدد
        IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
            UPDATE flocks
            SET current_count = current_count + OLD.count, updated_at = NOW()
            WHERE id = OLD.flock_id;
        ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
            -- إعادة تفعيل: ننقص العدد ذرياً
            UPDATE flocks
            SET current_count = current_count - NEW.count, updated_at = NOW()
            WHERE id = NEW.flock_id
              AND current_count >= NEW.count;

            GET DIAGNOSTICS v_affected = ROW_COUNT;
            IF v_affected = 0 THEN
                RAISE EXCEPTION 'العودة من الحذف: العدد المطلوب (%) يتجاوز الحالي', NEW.count;
            END IF;
        ELSE
            v_delta := NEW.count - OLD.count;

            IF v_delta > 0 THEN
                -- زيادة: ننقص الفرق ذرياً
                UPDATE flocks
                SET current_count = current_count - v_delta, updated_at = NOW()
                WHERE id = NEW.flock_id
                  AND current_count >= v_delta;

                GET DIAGNOSTICS v_affected = ROW_COUNT;
                IF v_affected = 0 THEN
                    RAISE EXCEPTION 'التعديل سيؤدي لعدد سالب (الفرق: %)', v_delta;
                END IF;
            ELSIF v_delta < 0 THEN
                -- إنقاص (استرجاع عدد)
                UPDATE flocks
                SET current_count = current_count + ABS(v_delta), updated_at = NOW()
                WHERE id = NEW.flock_id;
            END IF;
        END IF;

    ELSIF TG_OP = 'DELETE' THEN
        UPDATE flocks
        SET current_count = current_count + OLD.count, updated_at = NOW()
        WHERE id = OLD.flock_id;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_flock_count ON mortality;
CREATE TRIGGER trg_update_flock_count
    AFTER INSERT OR UPDATE OR DELETE ON mortality
    FOR EACH ROW EXECUTE FUNCTION public.update_flock_count_on_mortality();

-- 2) حماية inventory_items.quantity من الكتابة المباشرة عبر sync
-- الرصيد يُحسب فقط من inventory_transactions
-- نضيف trigger يمنع الكتابة المباشرة لـ quantity عبر sync_records_batch
CREATE OR REPLACE FUNCTION public.protect_inventory_quantity()
RETURNS TRIGGER AS $$
BEGIN
    -- السماح بالتعديل فقط عبر المعاملات (inventory_transactions)
    -- أو عبر الدوال SECURITY DEFINER (admin functions)
    -- يمنع sync من فرض quantity مباشر
    IF NEW.quantity IS DISTINCT FROM OLD.quantity THEN
        -- لا نسمح بالتعديل المباشر — يُحسب من Transactions
        RAISE EXCEPTION 'لا يمكن تعديل الرصيد مباشرة. استخدم معاملات المخزون';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- تفعيل الحماية على inventory_items
-- (يجب أن لا يُفعّل هذا على sync_records_batch لأنها SECURITY DEFINER)
-- نُفعّله فقط كحماية عامة — الدوال SECURITY DEFINER تتجاوزه
DROP TRIGGER IF EXISTS trg_protect_inventory_quantity ON inventory_items;
CREATE TRIGGER trg_protect_inventory_quantity
    BEFORE UPDATE ON inventory_items
    FOR EACH ROW EXECUTE FUNCTION public.protect_inventory_quantity();

-- 3) جدول الصراعات (conflicts) لتتبع صراعات المزامنة
CREATE TABLE IF NOT EXISTS sync_conflicts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    table_name TEXT NOT NULL,
    record_id UUID NOT NULL,
    farm_id UUID NOT NULL,
    local_data JSONB NOT NULL,
    remote_data JSONB NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'resolved', 'ignored')),
    resolution TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_sync_conflicts_status ON sync_conflicts(status);
CREATE INDEX IF NOT EXISTS idx_sync_conflicts_farm ON sync_conflicts(farm_id);

ALTER TABLE sync_conflicts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS conflicts_manager ON sync_conflicts;
CREATE POLICY conflicts_manager ON sync_conflicts
    FOR ALL TO authenticated
    USING (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    )
    WITH CHECK (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    );
