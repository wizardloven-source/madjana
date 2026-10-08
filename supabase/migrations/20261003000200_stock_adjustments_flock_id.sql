-- ============================================================
-- M2: stock_adjustments.flock_id + unit_price + currency
-- ============================================================
-- Adds:
--   flock_id  UUID REFERENCES flocks(id) ON DELETE RESTRICT
--   unit_price NUMERIC(12,4) CHECK (unit_price >= 0)
--   currency  TEXT NOT NULL DEFAULT 'SAR'
--            CHECK (currency IN ('SAR','USD','EUR'))
-- Fixes defect #5: farm_id ON DELETE CASCADE -> RESTRICT
-- ============================================================

BEGIN;

-- Fix defect #5: farm_id CASCADE would silently erase history
ALTER TABLE stock_adjustments
    DROP CONSTRAINT IF EXISTS stock_adjustments_farm_id_fkey,
    ADD CONSTRAINT stock_adjustments_farm_id_fkey
        FOREIGN KEY (farm_id) REFERENCES farms(id) ON DELETE RESTRICT;

-- flock_id: nullable (feed adjustments may not have a flock)
ALTER TABLE stock_adjustments
    DROP CONSTRAINT IF EXISTS stock_adjustments_flock_id_fkey,
    ADD COLUMN IF NOT EXISTS flock_id UUID,
    ADD CONSTRAINT stock_adjustments_flock_id_fkey
        FOREIGN KEY (flock_id) REFERENCES flocks(id) ON DELETE RESTRICT;

-- unit_price + currency
ALTER TABLE stock_adjustments
    ADD COLUMN IF NOT EXISTS unit_price NUMERIC(12,4)
        CHECK (unit_price >= 0),
    ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT 'dollar'
        CHECK (currency IN ('dollar', 'lira'));

COMMIT;
