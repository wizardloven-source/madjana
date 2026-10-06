-- ============================================================
-- ROLLBACK M3: medications.cost + currency + inventory_item_id
-- ============================================================
-- Guard: blocked if any medication has a cost value.
-- ============================================================

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM medications WHERE cost IS NOT NULL) THEN
        RAISE EXCEPTION 'cannot rollback: medications already have cost values';
    END IF;
END;
$$;

ALTER TABLE medications
    DROP CONSTRAINT IF EXISTS medications_inventory_item_id_fkey,
    DROP COLUMN IF EXISTS cost,
    DROP COLUMN IF EXISTS currency,
    DROP COLUMN IF EXISTS inventory_item_id;

COMMIT;
