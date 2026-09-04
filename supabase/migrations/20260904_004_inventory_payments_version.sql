-- ============================================================
-- Migration 20260904_004: inventory_items + payments version (OCC)
-- ============================================================
-- إضافة عمود version لعناصر المخزون لدعم OCC في sync_records_batch.
-- (من قبل لم يكن للجدول عمود version، فكانت محاولة update عبر
--  sync_records_batch تفشل بخطأ "column version does not exist").

-- 1) inventory_items.version
ALTER TABLE inventory_items
    ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1;

-- 2) payments.version (تأكيد — قد يكون موجوداً)
ALTER TABLE payments
    ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1;
