# 08 — Production Blockers

> Compiled from all audit phases on 2026-09-11.
> Updated 2026-09-11 after Phase 10-12 fixes.

## P0 — CRITICAL / RELEASE BLOCKERS

### BLOCKER-001: Self-Role Escalation via RLS ✅ FIXED
- **Severity:** P0
- **Feature:** Authentication / Authorization
- **File:** `supabase/migrations/UNIFIED_schema.sql:3182`
- **Fix file:** `supabase/migrations/UPGRADE_security_hardening.sql` (new migration)
- **Problem:** RLS policy `users_update_self` allows any authenticated user to UPDATE their own `users` row including the `role` column. No trigger or column-level grant prevents a worker from setting `role = 'system_admin'`.
- **Root cause:** No BEFORE UPDATE trigger guards the `role` column; RLS policy checks `id = auth.uid()` which allows self-update of all columns.
- **Fix applied:** Added `BEFORE UPDATE OF role ON users` trigger (`guard_user_role_change`) that raises `AUTHORIZATION_DENIED` unless caller is system_admin. Also added `BEFORE INSERT` trigger (`guard_user_role_insert`) to prevent non-admins from creating system_admin users. Bootstrap is exempted (SECURITY DEFINER with `auth.uid() = NULL`).
- **Regression test:** SQL-only — requires running Supabase to verify. Dart-side role dropdown fix provides defense in depth.

### BLOCKER-002: Bootstrap Token Dead Code / Race-Open First Run ✅ FIXED
- **Severity:** P0
- **Feature:** System Bootstrap
- **File:** `supabase/migrations/UNIFIED_schema.sql:2374-2473`
- **Fix file:** `supabase/migrations/UPGRADE_security_hardening.sql`
- **Problem:** `bootstrap_create_farm_and_manager` receives `p_provision_token` but never verifies it. Both bootstrap RPCs granted to `anon`. Whoever calls first claims system_admin.
- **Root cause:** Token parameter is unused in function body; only guard is `IF EXISTS (SELECT 1 FROM users)`.
- **Fix applied:** Added token verification step in the function that checks `p_provision_token` against `app_settings('secure.bootstrap_token')`. Returns `error: invalid provision token` on mismatch. Returns `error: provision token required` when null/empty. Returns `error: bootstrap token not configured` when server-side token not found.
- **Regression test:** SQL-only — requires running Supabase to verify.

### BLOCKER-003: device_id Never Populated in Sync ✅ FIXED
- **Severity:** P0
- **Feature:** Sync Engine / Sync Center
- **File:** `packages/data/lib/src/repositories/sync_repository_impl.dart:237-245`, `supabase/migrations/UNIFIED_schema.sql:1669`
- **Fix files:**
  - `packages/data/lib/src/datasources/local/local_database.dart` — added `getDeviceId()` static method + UUID v4 generator, persisted in `app_settings('device_id')`
  - `packages/data/lib/src/repositories/sync_repository_impl.dart:237` — `uploadBatch` now includes `device_id` in payload
  - `supabase/migrations/UPGRADE_security_hardening.sql` — `sync_records_batch` now reads `device_id` from record payload and writes it to `sync_changes`
- **Problem:** Client never sends `device_id` in upload payload. SQL INSERT into `sync_changes` omits `device_id` column. Column always NULL.
- **Fix applied:** Device UUID generated on first call to `LocalDatabase.getDeviceId()`, persisted in local `app_settings`, cached in memory. `uploadBatch()` fetches device_id and includes it in each record payload. SQL function `sync_records_batch` reads `v_device_id` from the request context and writes it to `sync_changes.device_id`.
- **Regression test:** `packages/data/test/device_id_regression_test.dart` — 4 tests: UUID format, persistence in app_settings, idempotency across calls, survives DB close/reopen. **ALL PASSED.**

### BLOCKER-004: Desktop Approvals Cross-Farm Data Leak ✅ FIXED
- **Severity:** P0
- **Feature:** Dispatch Approvals
- **File:** `apps/desktop/lib/features/approvals/presentation/approvals_screen.dart:47,63,77`
- **Problem:** Approvals screen queries `dispatch_requests` with no `farm_id` filter. Any manager sees ALL farms' requests. Can approve/reject another farm's requests.
- **Root cause:** Direct Supabase query bypasses repository layer and omits farm scoping.
- **Fix applied:** Added `.eq('farm_id', farmId)` filter to both the main data query and the pending count query in `_load()`. Farm ID sourced from `supabase.auth.currentUser?.userMetadata?['farm_id']`.
- **Regression test:** Requires integration test with authenticated Supabase session. Not unit-testable in isolation.

### BLOCKER-005: Emergency Screen Sends Nothing ✅ FIXED
- **Severity:** P0
- **Feature:** Emergency Alerts
- **File:** `apps/mobile/lib/features/emergency/emergency_screen.dart:173-200`
- **Problem:** `_sendEmergency` does `await Future.delayed(2s)` and shows success dialog. Nothing is sent to any manager. No repository, no API call, no push notification.
- **Root cause:** Stub implementation — `Future.delayed` simulates sending.
- **Fix applied:** Replaced stub with real `Supabase.from('app_notifications').insert(...)` call. Inserts a notification with `level: 'danger'`, `is_persistent: true`, `is_active: true`, `created_by: user.id`. Shows real error dialog on failure (network offline, missing farm_id, etc.). Added import for mobile `supabaseClientProvider`.
- **Regression test:** Requires integration test with authenticated Supabase session. Not unit-testable in isolation.

---

## P1 — HIGH

### BLOCKER-006: 4-digit PIN + Public Pepper + No Server-Enforced Lockout ⚠️ NOT FIXED
- **Severity:** P1
- **Feature:** Authentication
- **File:** `packages/data/lib/src/datasources/remote/supabase_auth_datasource.dart:118-127`
- **Problem:** `find_user_by_phone` (anon grant) is a phone enumeration oracle. Pepper `madjana$` is public. Lockout counters are client-enforced only (never checked by GoTrue). 10,000 PINs can be brute-forced against GoTrue directly.
- **Impact:** Account takeover via brute force, bypassing all client-side protections.
- **Status:** Requires server-side GoTrue changes beyond Flutter scope. Out of scope for this phase.

### BLOCKER-007: Desktop UsersScreen Lets Manager Create system_admin ✅ FIXED
- **Severity:** P1
- **Feature:** User Management
- **File:** `apps/desktop/lib/features/users/presentation/users_screen.dart:138-144`
- **Problem:** Role dropdown offers `worker`, `manager`, `system_admin` to any manager. No server-side check prevents manager from granting system_admin.
- **Fix applied:** Added `_isSystemAdmin` getter (reads `authProvider.currentUser.role`). Role dropdown items built dynamically — `system_admin` option only shown when current user is system_admin. Added guard that coerces `system_admin` to `worker` for non-admin callers editing existing users. Server-side trigger (P0-001) provides defense in depth.
- **Regression test:** Requires widget test with authenticated session. Not unit-testable.

### BLOCKER-008: resyncRequired Has No Recovery ✅ FIXED
- **Severity:** P1
- **Feature:** Sync Engine
- **File:** `packages/data/lib/src/repositories/sync_repository_impl.dart:411-413`
- **Problem:** When client falls behind retention window, `pullAndMerge` returns `resyncRequired: true`. No client-side full-resync exists. Device permanently stuck.
- **Fix applied:** In `syncNow()`, when `pullResult.resyncRequired == true`, the method now resets `sync_state.last_pulled_version` to 0 in the local database, then performs a second `pullAndMerge(farmId)` call immediately. This forces a fresh full pull from version 0.
- **Regression test:** Requires integration test with mock Supabase RPC. Not unit-testable in isolation.

### BLOCKER-009: Periodic Sync Dead After 5 Server Errors ✅ FIXED
- **Severity:** P1
- **Feature:** Sync Engine
- **File:** `apps/mobile/lib/features/sync/providers/sync_provider.dart:130-132`
- **Problem:** After 5 consecutive failed sync cycles, `_stopPeriodicSync()` is called permanently. Only restarts on connectivity change.
- **Fix applied:** Added `_backoffTimer`, `_backoffMinutes` field, and `_scheduleBackoffRetry()` method. After max failures, sync stops and schedules a delayed restart with exponential backoff (2min → 4min → 8min → 16min → 30min cap). On success, backoff counter and timer are cancelled. `_backoffTimer` is cancelled on dispose.
- **Regression test:** Requires integration test with fake ConnectivityService and SyncRepository. Not unit-testable in isolation.

### BLOCKER-010: Mortality Provider Data Loss on Image Upload ✅ FIXED
- **Severity:** P1
- **Feature:** Mortality Recording
- **File:** `apps/mobile/lib/features/mortality/providers/mortality_provider.dart:55-66`
- **Problem:** Image upload rebuilds `MortalityModel` discarding `sectionNo`, `version`, `previousVersion`, `syncStatus`, `createdAt`, `updatedAt`. Version resets to 1, breaking OCC conflict detection.
- **Fix applied:** Added `copyWith()` method to `MortalityModel`. Replaced manual constructor reconstruction with `record.copyWith(imageUrl: imageUrl)`. All fields preserved.
- **Regression test:** `packages/core/test/mortality_regression_test.dart` — 5 tests for `copyWith`: preserves all fields, updates only specified fields, no-op without args, null->value, null-means-keep semantics. **ALL PASSED.**

### BLOCKER-011: Division-by-Zero in Mortality Use Case ✅ FIXED
- **Severity:** P1
- **Feature:** Mortality Recording
- **File:** `packages/core/lib/src/usecases/save_mortality_usecase.dart:28`
- **Problem:** `getFlockCurrentCount` can return 0 (DAO returns 0 when flock missing). `(count/0)*100` → `Infinity`/`NaN` propagates to UI.
- **Fix applied:** Added zero-guard: `flockCount > 0 ? (record.count / flockCount) * 100 : 0.0`. When flock count is 0, mortality percentage is 0 and no high-mortality warning is triggered.
- **Regression test:** `packages/core/test/mortality_regression_test.dart` — 3 tests: zero flock count yields 0% and no warning, positive count yields correct percentage, below-threshold percentage yields no warning. **ALL PASSED.**

---

## P2 — MEDIUM

| ID | Finding | File | Status |
|----|---------|------|--------|
| P2-01 | Incomplete logout — offline credentials survive logout | `auth_repository_impl.dart:221-225` | **FIXED** — `logout()` now clears `offline_phone`, `offline_pin_hash`, `offline_user_json`, `offline_farm_id` |
| P2-02 | Stale auth — no JWT expiry handling, deactivated users stay logged in | `auth_provider.dart` (both apps) | OPEN |
| P2-03 | Conflict monitor screen is a stub (always empty) | `conflict_monitor_screen.dart:30-35` | OPEN |
| P2-04 | Pull overwrites local pending changes without checking queue | `sync_repository_impl.dart:436-467` | OPEN |
| P2-05 | Direct Supabase calls bypassing repository (notifications, dispatch, dashboard, approvals) | Multiple files | OPEN |
| P2-06 | autoSyncProvider wired but never consumed | `auto_sync_provider.dart` | OPEN |
| P2-07 | Chinese text in onboarding wizards | `new_flock_wizard_screen.dart:272`, `old_flock_wizard_screen.dart:275` | **FIXED** |
| P2-08 | Feed pricing → auto expense invoice logic in widget | `feed_screen.dart:471-508` | OPEN |
| P2-09 | Medicine ID generated in UI as DateTime milliseconds | `medicines_screen.dart:110` | OPEN |
| P2-10 | Settings screen controller leak (new TextEditingController every build, never disposed) | `settings_screen.dart:698` | OPEN |
| P2-11 | Dashboard feed-alert threshold hardcoded at 500kg | `dashboard_screen.dart:248` | OPEN |
| P2-12 | `flock.productionRate` formula appears incorrect | `flock_model.dart:33` | OPEN |
| P2-13 | Multiple mortality thresholds (1.0% use case vs 0.1%/0.2% FarmAnalytics) | `save_mortality_usecase.dart:30`, `farm_analytics.dart` | OPEN |
| P2-14 | Payments screen saves directly to repo with no offline queue / SyncStatus handling | `payments_screen.dart:168` | OPEN |
| P2-15 | `copyWith` createdAt reset bugs in Expense/Inventory models | `expense_model.dart`, `inventory_model.dart` | OPEN |
| P2-16 | Lira secondary amount in payments shows dollar value | `payments_screen.dart:288` | OPEN |
| P2-17 | Reports screen swallows all errors — spinner stuck forever on any throw | `reports_screen.dart:62-127` | OPEN |

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

| Severity | Original | Fixed | Remaining |
|----------|----------|-------|-----------|
| P0 — CRITICAL | 5 | 5 | 0 |
| P1 — HIGH | 6 | 5 | 1 (P1-006: requires server-side) |
| P2 — MEDIUM | 17 | 2 | 15 |
| P3 — LOW | 10 | 0 | 10 |
| **TOTAL** | **38** | **12** | **26** |
