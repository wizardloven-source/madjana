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
--
-- The "refuse to roll back once costs exist" guard lives in the ROLLBACK
-- file (20261003000301), not here: on a fresh database the cost column
-- does not exist yet, so a guard placed BEFORE the ALTER fails the very
-- first apply with `column "cost" does not exist`.
-- ============================================================

BEGIN;

ALTER TABLE medications
    ADD COLUMN IF NOT EXISTS cost NUMERIC(19,4)
        CHECK (cost IS NULL OR cost >= 0),
    ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT 'dollar'
        CHECK (currency IN ('dollar', 'lira')),
    ADD COLUMN IF NOT EXISTS inventory_item_id UUID;

-- PostgreSQL has no ADD CONSTRAINT IF NOT EXISTS. Without this guard the
-- CI idempotency pass (every migration applied a second time) dies with
-- "constraint medications_inventory_item_id_fkey already exists".
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'medications_inventory_item_id_fkey'
           AND conrelid = 'public.medications'::regclass
    ) THEN
        ALTER TABLE public.medications
            ADD CONSTRAINT medications_inventory_item_id_fkey
            FOREIGN KEY (inventory_item_id)
            REFERENCES public.inventory_items(id)
            ON DELETE SET NULL;
    END IF;
END;
$$;

COMMIT;
