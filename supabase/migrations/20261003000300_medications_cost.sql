-- ============================================================
-- M3: medications.cost + currency + inventory_item_id
-- ============================================================
-- Adds:
--   cost            numeric(19,4) NULL  CHECK (cost IS NULL OR cost >= 0)
--   currency        text NOT NULL DEFAULT 'dollar'
--                   CHECK (currency IN ('dollar', 'lira'))
--   inventory_item_id uuid NULL REFERENCES inventory_items(id) ON DELETE SET NULL
-- Priority logic (app-level, not DDL):
--   1. inventory_item_id → qty * unit_price
--   2. else cost
--   3. else 0 + manager warning
-- ============================================================

BEGIN;

-- Guard: rollback is blocked if any medication already has a cost
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM medications WHERE cost IS NOT NULL) THEN
        RAISE EXCEPTION 'cannot rollback: medications already have cost values';
    END IF;
END;
$$;

ALTER TABLE medications
    ADD COLUMN IF NOT EXISTS cost NUMERIC(19,4)
        CHECK (cost IS NULL OR cost >= 0),
    ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT 'dollar'
        CHECK (currency IN ('dollar', 'lira')),
    ADD COLUMN IF NOT EXISTS inventory_item_id UUID,
    ADD CONSTRAINT medications_inventory_item_id_fkey
        FOREIGN KEY (inventory_item_id) REFERENCES inventory_items(id) ON DELETE SET NULL;

COMMIT;
