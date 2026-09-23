-- ============================================================================
-- ترقية: تخفيف قيد loose_eggs في جدول egg_production
--
-- السبب: كان القيد يفرض (loose_eggs >= 0 AND loose_eggs < 30) أي أن عدد
-- البيض المتناثر (خارج الكراتين) يجب أن يقل عن 30. لكن التطبيق يسجّل فيه
-- مجموع البيض المتناثر لليوم كاملاً (قد يتجاوز آلاف البيض)، فكان كل إدراج
-- رقعه الخادم برفض (CHECK_CONSTRAINT_VIOLATION) أي «Sync error».
--
-- الإصلاح (إضافي): إبقاء الشرط >= 0 فقط ليطابق معنى الحقل في التطبيق.
-- لا يمسح أي بيانات، ولا يغير الفهرس الفريد (flock_id, date, section).
-- ============================================================================

ALTER TABLE public.egg_production
    DROP CONSTRAINT IF EXISTS egg_production_loose_eggs_check;

ALTER TABLE public.egg_production
    ADD CONSTRAINT egg_production_loose_eggs_check
        CHECK (loose_eggs >= 0);