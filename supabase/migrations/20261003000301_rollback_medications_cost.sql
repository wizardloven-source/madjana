-- ============================================================
-- ROLLBACK M3: medications.cost + currency + inventory_item_id
-- ============================================================
-- Guard: blocked if any medication has a cost value.
-- ============================================================

BEGIN;

-- Scope guard: refuse to drop cost data. Nested IFs, not AND: SQL makes no
-- short-circuit promise, so the column must be proven to exist before it
-- can be selected from -- on a database where M3 never ran, the outer check
-- is what makes this rollback a safe no-op instead of an error.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = 'medications'
                 AND column_name = 'cost') THEN
        IF EXISTS (SELECT 1 FROM public.medications WHERE cost IS NOT NULL) THEN
            RAISE EXCEPTION 'cannot rollback: medications already have cost values';
        END IF;
    END IF;
END;
$$;

ALTER TABLE medications
    DROP CONSTRAINT IF EXISTS medications_inventory_item_id_fkey,
    DROP COLUMN IF EXISTS cost,
    DROP COLUMN IF EXISTS currency,
    DROP COLUMN IF EXISTS inventory_item_id;

COMMIT;
