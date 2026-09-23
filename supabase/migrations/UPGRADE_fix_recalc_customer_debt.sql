-- ============================================================================
-- ترقية: إصلاح دالة recalc_customer_debt() — كانت تستخدم unnest() داخل WHERE
-- وهو غير مسموح به في Postgres (0A000)، مما كان يُفشل أي إدراج في جدول payments
-- وبالتالي كل المقبوضات لم تكن تصل إلى الخادم أبداً.
--
-- ملف إضافي (additive) — لا يمسح أي بيانات. يُطبَّق في محرر SQL (SQL Editor).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.recalc_customer_debt()
RETURNS TRIGGER AS $$
DECLARE
    v_cust uuid;
    v_custs uuid[];
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_custs := ARRAY[OLD.customer_id];
    ELSIF TG_OP = 'INSERT' THEN
        v_custs := ARRAY[NEW.customer_id];
    ELSE
        v_custs := ARRAY[OLD.customer_id, NEW.customer_id];
    END IF;

    PERFORM set_config('app.allow_debt_update', 'on', true);
    FOR v_cust IN
        SELECT DISTINCT v
        FROM unnest(v_custs) AS t(v)
        WHERE v IS NOT NULL
    LOOP
        UPDATE customers
        SET total_debt = COALESCE((
            SELECT SUM(total_due - amount_paid)
            FROM payments
            WHERE customer_id = v_cust AND deleted_at IS NULL
        ), 0),
        updated_at = NOW()
        WHERE id = v_cust;
    END LOOP;
    PERFORM set_config('app.allow_debt_update', 'off', true);
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- إعادة إنشاء المُشغِّل لضمان وجوده
DROP TRIGGER IF EXISTS trg_recalc_customer_debt ON payments;
CREATE TRIGGER trg_recalc_customer_debt
    AFTER INSERT OR UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION public.recalc_customer_debt();