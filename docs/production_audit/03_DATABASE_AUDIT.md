# 03 — Database & Migration Audit

> Read-only audit on 2026-09-11. All 5 SQL migration files inspected.

## 1. Migration Files

| # | File | Lines | Role |
|---|------|-------|------|
| 1 | `UNIFIED_schema.sql` | 3,275 | Bootstrap schema: 26 tables, functions, triggers, RLS, sync engine, admin RPCs |
| 2 | `UPGRADE_currency_carton.sql` | 409 | Additive: currency/exchange_rate on payments/expenses, carton expense category |
| 3 | `UPGRADE_multifarm_links.sql` | 796 | Additive: `user_farms` table, multi-farm identity/admin functions, updated RLS |
| 4 | `UPGRADE_sync_idempotent_insert.sql` | 406 | Additive: re-creates `sync_records_batch` tolerating duplicate inserts |
| 5 | `UPGRADE_sync_read_fix.sql` | 341 | Additive: re-creates pull/cleanup/compact/checkpoint chain (fixes GROUP BY bug) |

## 2. Migration Safety

| File | Safe? | Issue |
|------|-------|-------|
| `UNIFIED_schema.sql` | **BOOTSTRAP** | Full schema rebuild. Uses `IF NOT EXISTS` but is intended as initial deployment, not incremental migration. **Must NOT be run against an existing production database.** |
| `UPGRADE_currency_carton.sql` | SAFE | All `IF NOT EXISTS` / `CREATE OR REPLACE`. Additive only. No destructive ops. |
| `UPGRADE_multifarm_links.sql` | SAFE | Creates new table, adds new functions. `CREATE OR REPLACE` on functions. Additive. |
| `UPGRADE_sync_idempotent_insert.sql` | SAFE | `CREATE OR REPLACE FUNCTION`. No schema changes. |
| `UPGRADE_sync_read_fix.sql` | SAFE | `CREATE OR REPLACE FUNCTION`. No schema changes. |

**BLOCKED** — Cannot verify migration order without a running Supabase instance. Filename ordering suggests 1→5 but no version tracking exists in the SQL files.

## 3. Table Summary (26 tables)

### Core Business Tables
| Table | PK | Soft Delete | Version | Sync | RLS |
|-------|-----|-------------|---------|------|-----|
| `farms` | uuid | no | no | no | YES |
| `users` | uuid | no | no | no | YES |
| `user_farms` | composite | no | no | no | YES |
| `flocks` | uuid | `deleted_at` | `version` | trigger | YES |
| `customers` | uuid | `deleted_at` | `version` | trigger | YES |
| `egg_production` | uuid | `deleted_at` | `version` | trigger | YES |
| `mortality` | uuid | `deleted_at` | `version` | trigger | YES |
| `feed_consumption` | uuid | `deleted_at` | `version` | trigger | YES |
| `feed_received` | uuid | `deleted_at` | `version` | trigger | YES |
| `egg_dispatch` | uuid | `deleted_at` | `version` | trigger | YES |
| `medications` | uuid | `deleted_at` | `version` | trigger | YES |
| `expenses` | uuid | `deleted_at` | `version` | trigger | YES |
| `payments` | uuid | `deleted_at` | `version` | trigger | YES |
| `inventory_items` | uuid | no | `version` | trigger | YES |
| `inventory_transactions` | uuid | no | no | trigger | YES |
| `opening_balances` | uuid | no | no | trigger | YES |
| `dispatch_requests` | uuid | no | no | trigger | YES |
| `medicines_catalog` | uuid | no | no | no | YES |
| `app_settings` | text key | no | no | trigger | YES |
| `app_notifications` | uuid | no | no | trigger | YES |

### Infrastructure Tables
| Table | Purpose | RLS |
|-------|---------|-----|
| `sync_changes` | Change log for pull | YES |
| `sync_checkpoint` | Per-farm version watermark | no |
| `sync_conflicts` | Conflict records | YES |
| `idempotency_log` | Operation dedup | YES |
| `audit_log` | Action audit trail | YES |
| `login_throttle` | Rate limiting | no |

## 4. Key Database Functions

### Security/Identity
| Function | SECURITY DEFINER | Issue |
|----------|-----------------|-------|
| `current_user_role()` | no | Reads from `users` table |
| `current_user_farm_id()` | no | Reads from `users` table |
| `is_system_admin()` | YES | Checks role + is_active |
| `set_active_farm()` | YES | Updates `users.farm_id` + auth metadata |
| `app_password_from_pin()` | no | Returns `'madjana$' + pin` — pepper is public |
| `app_user_email()` | no | Returns synthetic email |

### Business Logic Triggers
| Trigger | Table | Purpose |
|---------|-------|---------|
| `trg_calc_total_eggs` | egg_production | Computes `cartons×per_carton + trays×per_tray + loose` |
| `trg_calc_dispatch_total` | egg_dispatch | Same for dispatch |
| `trg_validate_flock_farm` | egg_production, mortality, feed, medication, opening_balances | Cross-farm flock guard |
| `trg_validate_dispatch_refs` | dispatch_requests | Flock+customer must match farm |
| `trg_validate_payment_refs` | payments | Customer/dispatch farm match |
| `trg_guard_customer_debt` | customers | Blocks direct `total_debt` edits |
| `trg_recalc_customer_debt` | payments | Recomputes `total_debt` on payment change |
| `trg_update_flock_count` | mortality | Increments/decrements `current_count` |
| `trg_protect_inventory_quantity` | inventory_items | Blocks direct `quantity` edits |
| `trg_customers_scope_guard` | customers | Sets `is_global` based on role |

### Sync Engine
| Function | Purpose |
|----------|---------|
| `sync_records_batch()` | SECURITY DEFINER RPC — processes batch upload: idempotency, OCC, role whitelist, writes table + sync_changes + idempotency_log |
| `pull_remote_changes()` | SECURITY DEFINER RPC — returns changes since version watermark |
| `populate_sync_changes()` | Trigger function — writes to `sync_changes` after INSERT/UPDATE/DELETE on 16 operational tables |
| `cleanup_old_sync_changes()` | Purges old sync_changes beyond retention |
| `compact_sync_changes()` | Removes superseded consecutive UPDATE rows |
| `refresh_sync_checkpoint()` | Upserts version watermark per farm |
| `auto_maintain_sync()` | Runs cleanup+compact (called on every pull) |

### Admin RPCs (14 functions)
All SECURITY DEFINER, granted to `authenticated`:
- `bootstrap_create_farm_and_manager`, `create_first_admin`, `has_system_admin`
- `create_farm_with_manager`, `admin_create_farm`
- `admin_create_user`, `admin_update_user`, `admin_reset_pin`, `admin_delete_user`
- `admin_assign_user_to_farm`, `admin_unassign_user_from_farm`
- `admin_select_all_users_with_farms`, `admin_select_all_users`, `admin_select_all_farms`
- `admin_sync_health`

## 5. Critical Database Findings

| # | Severity | Finding | Evidence |
|---|----------|---------|----------|
| 1 | **P0** | **`device_id` never populated** — `sync_changes.device_id` always NULL because client doesn't send it and SQL INSERT omits the column | `sync_records_batch` line 1669, no `device_id` in INSERT; Flutter `uploadBatch` payload has no `device_id` field |
| 2 | **P0** | **Self-role escalation via RLS** — `users_update_self` allows any authenticated user to UPDATE their own row including the `role` column, with no column-level guard or trigger | `UNIFIED_schema.sql:3182`, `users` table has no BEFORE UPDATE trigger on `role` |
| 3 | **P1** | **Bootstrap token not verified** — `bootstrap_create_farm_and_manager` receives `p_provision_token` but never checks it | `UNIFIED_schema.sql:2374-2473` |
| 4 | **P1** | **Soft delete server / hard delete client mismatch** — server uses `deleted_at` soft delete, client `pullAndMerge` does `txn.delete()` hard delete | `sync_records_batch` line 1637 vs `sync_repository_impl.dart:447-449` |
| 5 | **MEDIUM** | **`resync_required` path unimplemented** — when client falls behind retention, it's permanently stuck | `pull_remote_changes` line 1806, no client-side recovery |
| 6 | **MEDIUM** | **`auto_maintain_sync()` called on every pull** — expensive cleanup runs on every `pull_remote_changes` call | `pull_remote_changes` line 1748 |
| 7 | **LOW** | **Inconsistent UUID generation** — `expenses`/`inventory_items` use `gen_random_uuid()`, all others use `uuid_generate_v4()` | Schema definitions |
| 8 | **LOW** | **RLS not explicitly enabled** on most tables — relies on Supabase dashboard defaults | Only `user_farms`, `idempotency_log`, `sync_conflicts` have `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` |
