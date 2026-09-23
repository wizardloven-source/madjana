-- ============================================================================
-- ترقية: إضافة فئة إيرادات "مبيعات البيض" (eggSales) لجدول revenue
--
-- ملاحظة: ملف إضافي (additive) - لا يمسح أي بيانات.
-- يُطبَّق في محرر SQL الخاص بـ Supabase (SQL Editor).
--
-- السبب: مقبوضات بيع البيض تُسجَّل في جدول payments من شاشة الدفعات،
--        والآن تم دمجها كإيراد "مبيعات البيض" في صفحة الإيرادات.
--        هذه الترقية تسمح أيضاً بإدخال إيراد بيض يدوي بنفس الفئة.
-- ============================================================================

-- إعادة تعريف قيد категоري ليشمل eggSales (مع تفادي الخطأ إن لم يوجد القيد)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'revenue'::regclass
          AND conname = 'revenue_category_check'
    ) THEN
        ALTER TABLE revenue DROP CONSTRAINT revenue_category_check;
    END IF;
END $$;

ALTER TABLE revenue ADD CONSTRAINT revenue_category_check
    CHECK (category IN ('liveChicken', 'eggSales', 'building', 'equipment', 'other'));