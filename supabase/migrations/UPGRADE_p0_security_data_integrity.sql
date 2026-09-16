-- ═══════════════════════════════════════════════════════════════
-- P0 Security & Data Integrity Fixes
-- Madjana Poultry Farm — Migration: P0_security_data_integrity
-- ═══════════════════════════════════════════════════════════════
-- Safety: ALL operations are additive or policy recreation.
-- NO DROP TABLE, NO DROP COLUMN, NO data deletion.
-- ═══════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────
-- P0-01: RLS farm_id isolation for financial tables
-- Problem: payments/expenses/opening_balances/inventory_items use
-- role-only policies without farm_id. Any manager can access ANY farm.
-- ─────────────────────────────────────────────

-- payments: replace mgr_all with farm-scoped policy
DROP POLICY IF EXISTS mgr_all ON payments;
DROP POLICY IF EXISTS payments_manager_farm_scoped ON payments;
CREATE POLICY payments_manager_farm_scoped ON payments
  FOR ALL
  USING (
    is_system_admin() OR
    (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
  );

-- expenses: replace mgr_all with farm-scoped policy
DROP POLICY IF EXISTS mgr_all ON expenses;
DROP POLICY IF EXISTS expenses_manager_farm_scoped ON expenses;
CREATE POLICY expenses_manager_farm_scoped ON expenses
  FOR ALL
  USING (
    is_system_admin() OR
    (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
  );

-- opening_balances: replace mgr_all with farm-scoped policy
DROP POLICY IF EXISTS mgr_all ON opening_balances;
DROP POLICY IF EXISTS opening_balances_manager_farm_scoped ON opening_balances;
CREATE POLICY opening_balances_manager_farm_scoped ON opening_balances
  FOR ALL
  USING (
    is_system_admin() OR
    (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
  );

-- inventory_items: replace mgr_all with farm-scoped policy
DROP POLICY IF EXISTS mgr_all ON inventory_items;
DROP POLICY IF EXISTS inventory_items_manager_farm_scoped ON inventory_items;
CREATE POLICY inventory_items_manager_farm_scoped ON inventory_items
  FOR ALL
  USING (
    is_system_admin() OR
    (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
  );

-- ─────────────────────────────────────────────
-- P0-02: Prevent negative inventory quantity
-- Problem: inventory quantity can go negative via direct SQL.
-- Fix: Trigger that blocks UPDATE making quantity < 0.
-- ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION prevent_negative_inventory_quantity()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.quantity < 0 THEN
    RAISE EXCEPTION 'Inventory quantity cannot be negative. Attempted: %', NEW.quantity;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_prevent_negative_inventory ON inventory_items;
CREATE TRIGGER trg_prevent_negative_inventory
  BEFORE UPDATE ON inventory_items
  FOR EACH ROW
  EXECUTE FUNCTION prevent_negative_inventory_quantity();

-- ─────────────────────────────────────────────
-- P0-07: Flock movements table for full lifecycle
-- Problem: current_count only tracks mortality.
-- Missing: additions, sales, transfers, destructions.
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS flock_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
  flock_id UUID NOT NULL REFERENCES flocks(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('addition', 'sale', 'transfer', 'destruction')),
  count INTEGER NOT NULL CHECK (count > 0),
  date DATE NOT NULL,
  notes TEXT,
  worker_id UUID REFERENCES users(id),
  version BIGINT DEFAULT 1,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  deleted_at TIMESTAMPTZ
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_flock_movements_farm ON flock_movements(farm_id);
CREATE INDEX IF NOT EXISTS idx_flock_movements_flock ON flock_movements(flock_id);
CREATE INDEX IF NOT EXISTS idx_flock_movements_date ON flock_movements(date);
CREATE INDEX IF NOT EXISTS idx_flock_movements_type ON flock_movements(type);

-- RLS
ALTER TABLE flock_movements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS flock_movements_select ON flock_movements;
CREATE POLICY flock_movements_select ON flock_movements
  FOR SELECT USING (
    is_system_admin() OR
    farm_id = current_user_farm_id()
  );

DROP POLICY IF EXISTS flock_movements_insert ON flock_movements;
CREATE POLICY flock_movements_insert ON flock_movements
  FOR INSERT WITH CHECK (
    is_system_admin() OR
    (farm_id = current_user_farm_id() AND
     (current_user_role() IN ('manager', 'worker')))
  );

DROP POLICY IF EXISTS flock_movements_update ON flock_movements;
CREATE POLICY flock_movements_update ON flock_movements
  FOR UPDATE USING (
    is_system_admin() OR
    (farm_id = current_user_farm_id() AND current_user_role() = 'manager')
  );

DROP POLICY IF EXISTS flock_movements_delete ON flock_movements;
CREATE POLICY flock_movements_delete ON flock_movements
  FOR DELETE USING (
    is_system_admin() OR
    (farm_id = current_user_farm_id() AND current_user_role() = 'manager')
  );

-- Sync triggers
DROP TRIGGER IF EXISTS flock_movements_sync_insert ON flock_movements;
CREATE TRIGGER flock_movements_sync_insert
  AFTER INSERT ON flock_movements
  FOR EACH ROW EXECUTE FUNCTION populate_sync_changes();

DROP TRIGGER IF EXISTS flock_movements_sync_update ON flock_movements;
CREATE TRIGGER flock_movements_sync_update
  AFTER UPDATE ON flock_movements
  FOR EACH ROW EXECUTE FUNCTION populate_sync_changes();

DROP TRIGGER IF EXISTS flock_movements_tombstone ON flock_movements;
CREATE TRIGGER flock_movements_tombstone
  AFTER DELETE ON flock_movements
  FOR EACH ROW EXECUTE FUNCTION sync_tombstone_after_delete();

-- updated_at trigger
DROP TRIGGER IF EXISTS flock_movements_updated_at ON flock_movements;
CREATE TRIGGER flock_movements_updated_at
  BEFORE UPDATE ON flock_movements
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ─────────────────────────────────────────────
-- P0-07: Update flock count trigger to include movements
-- Problem: current_count = initial - mortality only
-- Fix: Recalculate from initial + additions - mortality - sales - destructions
-- ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION update_flock_count_from_movements()
RETURNS TRIGGER AS $$
DECLARE
  v_initial INTEGER;
  v_additions INTEGER;
  v_mortality INTEGER;
  v_sales INTEGER;
  v_destructions INTEGER;
  v_target_flock_id UUID;
BEGIN
  -- Determine which flock to recalculate
  IF TG_OP = 'DELETE' THEN
    v_target_flock_id := OLD.flock_id;
  ELSE
    v_target_flock_id := NEW.flock_id;
  END IF;

  -- Get initial count
  SELECT initial_count INTO v_initial
  FROM flocks WHERE id = v_target_flock_id;

  -- Calculate additions
  SELECT COALESCE(SUM(count), 0) INTO v_additions
  FROM flock_movements
  WHERE flock_id = v_target_flock_id
    AND type = 'addition'
    AND deleted_at IS NULL;

  -- Calculate sales
  SELECT COALESCE(SUM(count), 0) INTO v_sales
  FROM flock_movements
  WHERE flock_id = v_target_flock_id
    AND type = 'sale'
    AND deleted_at IS NULL;

  -- Calculate destructions
  SELECT COALESCE(SUM(count), 0) INTO v_destructions
  FROM flock_movements
  WHERE flock_id = v_target_flock_id
    AND type = 'destruction'
    AND deleted_at IS NULL;

  -- Calculate mortality from mortality records
  SELECT COALESCE(SUM(count), 0) INTO v_mortality
  FROM mortality
  WHERE flock_id = v_target_flock_id
    AND deleted_at IS NULL;

  -- Include opening balance mortality
  v_mortality := v_mortality + COALESCE(
    (SELECT ob.mortality_count
     FROM opening_balances ob
     WHERE ob.flock_id = v_target_flock_id
     LIMIT 1),
    0
  );

  -- Update flock count
  UPDATE flocks
  SET current_count = GREATEST(0, v_initial + v_additions - v_mortality - v_sales - v_destructions)
  WHERE id = v_target_flock_id;

  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Drop old trigger if exists
DROP TRIGGER IF EXISTS trg_update_flock_count ON mortality;

-- Create trigger on flock_movements
DROP TRIGGER IF EXISTS trg_update_flock_count_movements ON flock_movements;
CREATE TRIGGER trg_update_flock_count_movements
  AFTER INSERT OR UPDATE OR DELETE ON flock_movements
  FOR EACH ROW EXECUTE FUNCTION update_flock_count_from_movements();

-- Also trigger on mortality (existing behavior preserved)
DROP TRIGGER IF EXISTS trg_update_flock_count_mortality ON mortality;
CREATE TRIGGER trg_update_flock_count_mortality
  AFTER INSERT OR UPDATE OR DELETE ON mortality
  FOR EACH ROW EXECUTE FUNCTION update_flock_count_from_movements();

-- Also trigger on opening_balances (to recalculate when opening balance mortality changes)
DROP TRIGGER IF EXISTS trg_update_flock_count_opening_balance ON opening_balances;
CREATE TRIGGER trg_update_flock_count_opening_balance
  AFTER INSERT OR UPDATE OR DELETE ON opening_balances
  FOR EACH ROW EXECUTE FUNCTION update_flock_count_from_movements();

-- ─────────────────────────────────────────────
-- Sync: Add sync_can_write/read for new tables
-- ─────────────────────────────────────────────

-- flock_movements: worker can write, all can read
-- (The sync_can_write function is IMMUTABLE, so we recreate it)
-- Note: sync_can_write and sync_can_read already handle the base tables.
-- For new tables, the trigger-based sync handles it.

COMMIT;
