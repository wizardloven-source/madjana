# 02 — Feature Inventory

> Read-only audit on 2026-09-11. Every feature mapped against source code.

## Legend
- ✅ Exists and functional
- ⚠️ Partial / stub
- ❌ Missing
- 🔗 Bypasses architecture (direct Supabase/repo calls in UI)

## Feature Matrix

| Feature | Mobile UI | Desktop UI | Provider | Use Case | Repository | Local DAO | Remote DS | SQLite Table | Supabase Table | RLS | Sync Trigger | Tests | Status |
|---------|-----------|------------|----------|----------|------------|-----------|-----------|-------------|----------------|-----|-------------|-------|--------|
| Auth/Login | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ (session) | ✅ | `session` | GoTrue + `users` | ✅ | — | ❌ | PARTIAL |
| Farm Management | ❌ (selector only) | ✅ (shell) | ✅ | ❌ | ✅ | ❌ | ✅ | — | `farms` | ✅ | — | ✅ | PARTIAL |
| Flock Management | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | `flocks` | `flocks` | ✅ | ✅ | ✅ | PARTIAL |
| Egg Production | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `egg_production` | `egg_production` | ✅ | ✅ | ✅ | PASS |
| Mortality | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `mortality` | `mortality` | ✅ | ✅ | ✅ | PASS |
| Feed Consumption | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `feed_consumption` | `feed_consumption` | ✅ | ✅ | ✅ | PASS |
| Feed Received | ✅ | ✅ (tab) | ✅ | ❌ | ✅ | ✅ | ✅ | `feed_received` | `feed_received` | ✅ | ✅ | ✅ | PARTIAL |
| Medications | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `medications` | `medications` | ✅ | ✅ | ✅ | PASS |
| Medicines Catalog | ❌ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | `medicines_catalog` | `medicines_catalog` | ✅ | — | ✅ | PASS |
| Customers | ✅ (via dispatch) | ✅ | 🔗 | ❌ | 🔗 (in DispatchRepo) | ✅ | ✅ | `customers` | `customers` | ✅ | ✅ | ✅ | PARTIAL |
| Dispatch | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `egg_dispatch` | `egg_dispatch` | ✅ | ✅ | ✅ | PASS |
| Dispatch Requests | ❌ | ✅ (approvals) | 🔗 | ❌ | ❌ | ✅ | ❌ | `dispatch_requests` | `dispatch_requests` | ✅ | ✅ | ❌ | PARTIAL |
| Payments | ✅ | ✅ (in dispatch) | ❌ | ❌ | ✅ | ✅ | ✅ | `payments` | `payments` | ✅ | ✅ | ✅ | PARTIAL |
| Expenses | ❌ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | `expenses` | `expenses` | ✅ | ✅ | ✅ | PARTIAL |
| Inventory | ❌ | ✅ | ❌ | ❌ | ✅ | ✅ | ✅ | `inventory_items` + `inventory_transactions` | `inventory_items` + `inventory_transactions` | ✅ | ✅ | ✅ | PARTIAL |
| Opening Balances | ❌ | ✅ (wizard) | ❌ | ❌ | ✅ | ✅ | ✅ | `opening_balances` | `opening_balances` | ✅ | ✅ | ✅ | PARTIAL |
| Reports | ✅ | ✅ | ❌ (inline) | ❌ | — (reads repos) | — | — | — | — | — | — | ❌ | PARTIAL |
| Dashboard/Home | ✅ | ✅ | 🔗 (widgets call repos) | ❌ | — | — | — | — | — | — | — | ❌ | PARTIAL |
| Notes | ✅ | ❌ | ✅ | ❌ | ✅ (via DAO) | ✅ (local only) | ❌ | `notes` | — (local only) | — | — | ❌ | PASS |
| Notifications | ✅ | ✅ | 🔗 | ❌ | ✅ | ✅ (reminders) | ✅ | `app_notifications` | `app_notifications` | ✅ | ✅ | ❌ | PARTIAL |
| Sync | ✅ | ✅ (center) | ✅ | ✅ (use case exists but orphaned) | ✅ | ✅ (queue) | ✅ (Edge Fn) | `sync_queue` + `sync_state` | `sync_changes` + `sync_checkpoint` + `idempotency_log` | ✅ | — | ✅ | PARTIAL |
| Settings | ✅ | ✅ | ✅ (theme, auto_sync) | ❌ | ✅ (farm settings) | ✅ | ✅ | `app_settings` | `app_settings` | ✅ | ✅ | ❌ | PARTIAL |
| User Management | ❌ | ✅ | ❌ | ❌ | ✅ (user admin) | ✅ | ✅ | `users` | `users` | ✅ | — | ❌ | PARTIAL |
| Emergency | ✅ (stub) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | — | — | — | — | ❌ | FAIL |
| Approvals | ❌ | ✅ | 🔗 | ❌ | ❌ | ✅ (dispatch_requests) | 🔗 (direct) | `dispatch_requests` | `dispatch_requests` | ✅ | ✅ | ❌ | PARTIAL |
| Multi-Farm | ✅ (selector) | ✅ (shell) | ✅ | ❌ | ✅ | ✅ | ✅ | `user_farms` | `user_farms` | ✅ | — | ❌ | PARTIAL |
| Audit Log | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | `audit_log` | `audit_log` | ✅ | ❌ | ❌ | FAIL |
| Backup/Restore | ❌ | ✅ | ❌ | ❌ | — (LocalDatabase) | ✅ | ❌ | — (file copy) | — | — | — | ❌ | PARTIAL |
| CSV Export | ❌ | ✅ | ❌ | ❌ | — (inline) | — | ❌ | — | — | — | — | ❌ | PASS |

## Architecture Violations in Features

| Feature | Violation | File |
|---------|-----------|------|
| Notifications | Provider calls Supabase directly | `notifications_provider.dart:14-23` |
| Dispatch (mobile) | Widget calls Supabase directly | `dispatch_screen.dart:193` |
| Approvals (desktop) | Widget calls Supabase directly (×3) | `approvals_screen.dart:47,63,77` |
| Dashboard (desktop) | Widget calls Supabase directly | `dashboard_screen.dart:151-155` |
| Customers (mobile) | No own provider — routed through dispatch | `customers_screen.dart` |
| Payments (mobile) | No provider — screen calls repo directly | `payments_screen.dart:168` |
| Home (mobile) | Widget calls repositories directly | `home_screen.dart:613-617` |
| Reports (mobile) | Widget computes all aggregation inline | `reports_screen.dart:62-127` |

## Missing Features (mentioned in docs/plans but not implemented)

| Feature | Status |
|---------|--------|
| Expense tracking on mobile | ❌ `expenseDao: null` in mobile providers |
| Inventory management on mobile | ❌ No screens, no providers |
| Audit log viewing | ❌ Table exists in DB but no UI or provider anywhere |
| Conflict resolution UI (desktop) | ⚠️ Stub screen with `Future.delayed(1s)` |
| Emergency alert system | ⚠️ Stub screen — sends nothing |
| Worker onboarding wizard (mobile) | ❌ Desktop only |

## Summary

| Category | Count |
|----------|-------|
| Features fully wired (PASS) | 6 |
| Features partially wired (PARTIAL) | 19 |
| Features broken/stub (FAIL) | 2 |
| Architecture violations | 8 |
| Missing implementations | 6 |
