
## 5. Inventory trays (W8)

### Purpose

The tray inventory is **server-managed** via database triggers (SECURITY DEFINER). Two system items exist per farm:
- `trays_empty` (unit: `piece`) – empty carton trays. Increased on **carton purchases** (`expenses.category='carton'`, `carton_bundles × trays_per_bundle`). Decreased on **egg production**.
- `trays_filled` (unit: `piece`) – filled trays. Increased on **egg production**. Decreased on **egg dispatch**.

Egg cartons are **derived** from filled trays (`trays_per_carton = eggs_per_tray ? floor(eggs_per_carton/eggs_per_tray)`; UI displays cartons + loose trays). There is no separate `cartons` counter persisted; the ledger is `inventory_transactions`.

### Triggers (AFTER INSERT/UPDATE/DELETE)

- `trg_trays_on_production` (on `egg_production`): 
  - `delta_trays = CEIL(new.total_eggs / eggs_per_tray) − CEIL(old.total_eggs / eggs_per_tray)`
  - applies `+delta_trays` to `trays_filled`, `−delta_trays` to `trays_empty`
- `trg_trays_on_dispatch` (on `egg_dispatch`): 
  - `delta_trays = CEIL(old.total_eggs / eggs_per_tray) − CEIL(new.total_eggs / eggs_per_tray)` (reversal on update/delete)
  - applies `+delta_trays` to `trays_filled` (net outflow)
- `trg_trays_on_carton_purchase` (on `expenses` where `category='carton'`): 
  - `delta = (new.carton_bundles − old.carton_bundles) × trays_per_bundle`
  - applies `+delta` to `trays_empty`

All delta calculations use `CEIL(total_eggs / eggs_per_tray)` per user-approved rule. UPDATE and DELETE are handled via before/after row deltas (reversal on delete).

### Protection

- `protect_inventory_quantity()` allows `quantity` changes only when `app.allow_inventory_update = 'on'` (set by the system triggers via `set_config(..., true)` inside transaction, then reset to `off`). Direct client UPDATE of `quantity` raises `لا يمكن تعديل الرصيد مباشرة. استخدم معاملات المخزون`.
- `prevent_negative_inventory_quantity()`: for system items (`system_key IS NOT NULL`) a negative `quantity` produces a **WARNING** (logged) rather than aborting the operation; for non-system items it raises an exception.
- `inventory_items.quantity` CHECK `(>=0)` is **dropped** (system items may momentarily appear negative in edge cases but ledger remains source of truth).
- Every update to `inventory_items` sets `version = version + 1` and `updated_at = now()`.

### Ledger & sync

- Movements are written to `inventory_transactions` (type `in`/`out`, quantity = `abs(delta)`). `stock_adjustments` remains for manual financial adjustments (flock cost) and is not used by these triggers.
- `populate_sync_changes()` is hardened for `inventory_transactions` (derives `farm_id` via the linked `inventory_items` item; does not rely on `NEW.farm_id` which may be absent).
- `sync_can_read('worker', 'inventory_items') = true` (read-only for workers). `sync_can_write('worker', 'inventory_items') = false`. `sync_can_read/write` for worker include `revenue` and `dispatch_requests` per canonical contract (`20260926000100_sync_publish_revenue_and_occ.sql`); `inventory_items` added only to worker read list.
- RLS: worker may `SELECT` `inventory_items` for their own farm (`inventory_items_worker_select`). Managers retain full access.

### Configuration

- `farms.trays_per_bundle` INTEGER NOT NULL DEFAULT 100, CHECK (>0).
- `inventory_items.system_key` TEXT, UNIQUE `(farm_id, system_key)` (NULLs allowed for user items).
- System items created on migration backfill for all existing farms (`trays_empty`, `trays_filled`, quantity 0).

---
