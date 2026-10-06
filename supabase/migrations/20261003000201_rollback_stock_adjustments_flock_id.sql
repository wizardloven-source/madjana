-- ============================================================
-- ROLLBACK M2: stock_adjustments.flock_id + unit_price + currency
-- ============================================================
-- NOTE: does NOT restore farm_id ON DELETE CASCADE (defect #5).
-- The correct state is RESTRICT; rollback only removes M2 columns.
-- ============================================================

BEGIN;

ALTER TABLE stock_adjustments
    DROP CONSTRAINT IF EXISTS stock_adjustments_flock_id_fkey,
    DROP COLUMN IF EXISTS flock_id,
    DROP COLUMN IF EXISTS unit_price,
    DROP COLUMN IF EXISTS currency;

-- farm_id stays RESTRICT (defect #5 fix is not rolled back)

COMMIT;
