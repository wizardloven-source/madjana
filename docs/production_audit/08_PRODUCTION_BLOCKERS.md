# 08 — Production Blockers

> Compiled from all audit phases on 2026-09-11.

## P0 — CRITICAL / RELEASE BLOCKERS

### BLOCKER-001: Self-Role Escalation via RLS
- **Severity:** P0
- **Feature:** Authentication / Authorization
- **File:** `supabase/migrations/UNIFIED_schema.sql:3182`
- **Problem:** RLS policy `users_update_self` allows any authenticated user to UPDATE their own `users` row including the `role` column. No trigger or column-level grant prevents a worker from setting `role = 'system_admin'`.
- **Root cause:** No BEFORE UPDATE trigger guards the `role` column; RLS policy checks `id = auth.uid()` which allows self-update of all columns.
- **Impact:** Any worker can escalate to system_admin, gaining full platform access including cross-farm data visibility and user management.
- **Proof:** Source-code inspection of RLS policy at `UNIFIED_schema.sql:3182`. No `users_role_guard` trigger exists anywhere in the schema.
- **Recommended fix:** Add `BEFORE UPDATE OF role ON users` trigger that raises unless caller is system_admin. Or remove `role` from the UPDATE column grant.
- **Test required:** SQL test verifying worker UPDATE on own `role` is denied.

### BLOCKER-002: Bootstrap Token Dead Code / Race-Open First Run
- **Severity:** P0
- **Feature:** System Bootstrap
- **File:** `supabase/migrations/UNIFIED_schema.sql:2374-2473`
- **Problem:** `bootstrap_create_farm_and_manager` receives `p_provision_token` but never verifies it. Both bootstrap RPCs granted to `anon`. Whoever calls first claims system_admin.
- **Root cause:** Token parameter is unused in function body; only guard is `IF EXISTS (SELECT 1 FROM users)`.
- **Impact:** On a fresh Supabase project, any anonymous caller can create the first system_admin farm. Token provides zero protection.
- **Proof:** Function body inspection — no `WHERE` clause or comparison on `p_provision_token`.
- **Recommended fix:** Verify token against `app_settings('secure.bootstrap_token')`, or remove the door and provision the first admin out-of-band.
- **Test required:** SQL test verifying bootstrap fails with wrong token.

### BLOCKER-003: device_id Never Populated in Sync
- **Severity:** P0
- **Feature:** Sync Engine / Sync Center
- **File:** `packages/data/lib/src/repositories/sync_repository_impl.dart:237-245`, `supabase/migrations/UNIFIED_schema.sql:1669`
- **Problem:** Client never sends `device_id` in upload payload. SQL INSERT into `sync_changes` omits `device_id` column. Column always NULL.
- **Root cause:** Missing field in client payload + missing column in SQL INSERT.
- **Impact:** Desktop SyncCenter device count always 0. Online/offline indicators permanently zero. No device-level sync health visibility.
- **Proof:** Payload construction at `sync_repository_impl.dart:237-245` — no `device_id` key. SQL INSERT at line 1669 — no `device_id` in column list.
- **Recommended fix:** Generate and persist device UUID on first launch; include in payload; include in SQL INSERT.
- **Test required:** Sync test verifying `device_id` is populated in `sync_changes`.

### BLOCKER-004: Desktop Approvals Cross-Farm Data Leak
- **Severity:** P0
- **Feature:** Dispatch Approvals
- **File:** `apps/desktop/lib/features/approvals/presentation/approvals_screen.dart:47,63,77`
- **Problem:** Approvals screen queries `dispatch_requests` with no `farm_id` filter. Any manager sees ALL farms' requests. Can approve/reject another farm's requests.
- **Root cause:** Direct Supabase query bypasses repository layer and omits farm scoping.
- **Impact:** Cross-farm data exposure. Manager of Farm A can see and act on Farm B's dispatch requests.
- **Proof:** Source inspection — `.from('dispatch_requests').select('*')` with no `.eq('farm_id', ...)`.
- **Recommended fix:** Add `.eq('farm_id', currentFarmId)` filter, or route through repository layer.
- **Test required:** Integration test verifying manager only sees own farm's requests.

### BLOCKER-005: Emergency Screen Sends Nothing
- **Severity:** P0
- **Feature:** Emergency Alerts
- **File:** `apps/mobile/lib/features/emergency/emergency_screen.dart:173-200`
- **Problem:** `_sendEmergency` does `await Future.delayed(2s)` and shows success dialog. Nothing is sent to any manager. No repository, no API call, no push notification.
- **Root cause:** Stub implementation — `Future.delayed` simulates sending.
- **Impact:** Users believe emergency alerts are being sent. They are not. Farm safety risk.
- **Proof:** Source inspection — `_sendEmergency` body is `await Future.delayed(Duration(seconds: 2))` + success dialog.
- **Recommended fix:** Implement via `NotificationRepository` or remove the feature.
- **Test required:** Integration test verifying notification is created in database.

---

## P1 — HIGH

### BLOCKER-006: 4-digit PIN + Public Pepper + No Server-Enforced Lockout
- **Severity:** P1
- **Feature:** Authentication
- **File:** `packages/data/lib/src/datasources/remote/supabase_auth_datasource.dart:118-127`
- **Problem:** `find_user_by_phone` (anon grant) is a phone enumeration oracle. Pepper `madjana$` is public. Lockout counters are client-enforced only (never checked by GoTrue). 10,000 PINs can be brute-forced against GoTrue directly.
- **Impact:** Account takeover via brute force, bypassing all client-side protections.
- **Recommended fix:** Move lockout to server-side (e.g., Edge Function wrapper around GoTrue, or per-email throttling).

### BLOCKER-007: Desktop UsersScreen Lets Manager Create system_admin
- **Severity:** P1
- **Feature:** User Management
- **File:** `apps/desktop/lib/features/users/presentation/users_screen.dart:138-144`
- **Problem:** Role dropdown offers `worker`, `manager`, `system_admin` to any manager. No server-side check prevents manager from granting system_admin.
- **Impact:** Privilege escalation from manager to system_admin.
- **Recommended fix:** Filter dropdown to max `manager` for non-system_admin users; add server-side role guard in `admin_create_user`.

### BLOCKER-008: resyncRequired Has No Recovery
- **Severity:** P1
- **Feature:** Sync Engine
- **File:** `packages/data/lib/src/repositories/sync_repository_impl.dart:411-413`
- **Problem:** When client falls behind retention window, `pullAndMerge` returns `resyncRequired: true`. No client-side full-resync exists. Device permanently stuck.
- **Impact:** Device loses sync permanently; all local data diverges from cloud.
- **Recommended fix:** Implement full data reload on `resyncRequired`.

### BLOCKER-009: Periodic Sync Dead After 5 Server Errors
- **Severity:** P1
- **Feature:** Sync Engine
- **File:** `apps/mobile/lib/features/sync/providers/sync_provider.dart:130-132`
- **Problem:** After 5 consecutive failed sync cycles, `_stopPeriodicSync()` is called permanently. Only restarts on connectivity change.
- **Impact:** If server returns errors but network is fine, sync stops forever until manual intervention.
- **Recommended fix:** Add automatic restart with exponential backoff (e.g., restart after 5min, 15min, 30min).

### BLOCKER-010: Mortality Provider Data Loss on Image Upload
- **Severity:** P1
- **Feature:** Mortality Recording
- **File:** `apps/mobile/lib/features/mortality/providers/mortality_provider.dart:55-66`
- **Problem:** Image upload rebuilds `MortalityModel` discarding `sectionNo`, `version`, `previousVersion`, `syncStatus`, `createdAt`, `updatedAt`. Version resets to 1, breaking OCC conflict detection.
- **Impact:** After image upload, record's version resets, causing false OCC conflicts on next sync.
- **Recommended fix:** Use `copyWith` to preserve all fields when updating `imageUrl`.

### BLOCKER-011: Division-by-Zero in Mortality Use Case
- **Severity:** P1
- **Feature:** Mortality Recording
- **File:** `packages/core/lib/src/usecases/save_mortality_usecase.dart:28`
- **Problem:** `getFlockCurrentCount` can return 0 (DAO returns 0 when flock missing). `(count/0)*100` → `Infinity`/`NaN` propagates to UI.
- **Impact:** NaN displayed in mortality percentage; potential app crash.
- **Recommended fix:** Guard against zero count before division.

---

## P2 — MEDIUM

| ID | Finding | File |
|----|---------|------|
| P2-01 | Incomplete logout — offline credentials, sync_queue, cached data survive logout | `auth_repository_impl.dart:221-225` |
| P2-02 | Stale auth — no JWT expiry handling, deactivated users stay logged in | `auth_provider.dart` (both apps) |
| P2-03 | Conflict monitor screen is a stub (always empty) | `conflict_monitor_screen.dart:30-35` |
| P2-04 | Pull overwrites local pending changes without checking queue | `sync_repository_impl.dart:436-467` |
| P2-05 | Direct Supabase calls bypassing repository (notifications, dispatch, dashboard, approvals) | Multiple files |
| P2-06 | autoSyncProvider wired but never consumed | `auto_sync_provider.dart` |
| P2-07 | Chinese text in onboarding wizards | `new_flock_wizard_screen.dart:272`, `old_flock_wizard_screen.dart:275` |
| P2-08 | Feed pricing → auto expense invoice logic in widget | `feed_screen.dart:471-508` |
| P2-09 | Medicine ID generated in UI as DateTime milliseconds | `medicines_screen.dart:110` |
| P2-10 | Settings screen controller leak (new TextEditingController every build, never disposed) | `settings_screen.dart:698` |
| P2-11 | Dashboard feed-alert threshold hardcoded at 500kg | `dashboard_screen.dart:248` |
| P2-12 | `flock.productionRate` formula appears incorrect | `flock_model.dart:33` |
| P2-13 | Multiple mortality thresholds (1.0% use case vs 0.1%/0.2% FarmAnalytics) | `save_mortality_usecase.dart:30`, `farm_analytics.dart` |
| P2-14 | Payments screen saves directly to repo with no offline queue / SyncStatus handling | `payments_screen.dart:168` |
| P2-15 | `copyWith` createdAt reset bugs in Expense/Inventory models | `expense_model.dart`, `inventory_model.dart` |
| P2-16 | Lira secondary amount in payments shows dollar value | `payments_screen.dart:288` |
| P2-17 | Reports screen swallows all errors — spinner stuck forever on any throw | `reports_screen.dart:62-127` |

---

## P3 — LOW

| ID | Finding | File |
|----|---------|------|
| P3-01 | `SyncQueueDao` orphaned — provided but never called | `sync_queue_dao.dart` |
| P3-02 | `SyncDataUseCase` orphaned — never referenced | `sync_data_usecase.dart` |
| P3-03 | `rejectedIds` declared but never used | `sync_repository_impl.dart:277` |
| P3-04 | `referenceDataReadyProvider` is a no-op void provider | `reference_data_provider.dart:31-33` |
| P3-05 | Empty `catch (_) {}` patterns throughout auth flows | Multiple files |
| P3-06 | `currencyProvider` always returns `$` | `providers.dart:178` (desktop) |
| P3-07 | `SyncConnectionStatus` enum defined in mobile instead of core | `sync_provider.dart:44` |
| P3-08 | Two different operation ID generators | `local_database.dart:1061`, `sync_repository_impl.dart:86` |
| P3-09 | Domain package is empty barrel re-export | `packages/domain/lib/domain.dart` |
| P3-10 | CI only tests data package — core tests not in CI | `.github/workflows/ci.yml` |

---

## Summary

| Severity | Count |
|----------|-------|
| P0 — CRITICAL | 5 |
| P1 — HIGH | 6 |
| P2 — MEDIUM | 17 |
| P3 — LOW | 10 |
| **TOTAL** | **38** |
