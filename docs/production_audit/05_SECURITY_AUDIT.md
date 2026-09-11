# 05 — Security Audit

> Read-only audit on 2026-09-11. All auth, authz, and security-sensitive code inspected.

## 1. Authentication

### Login Flow
1. User enters phone + 4-digit PIN
2. Client calls `find_user_by_phone(phone)` RPC → returns `user_id` (anon grant — phone enumeration possible)
3. Client calls `signInWithPassword(email: '<uid>@users.madjana.local', password: 'madjana$<pin>')`
4. GoTrue verifies bcrypt hash server-side
5. Client extracts role/farm from JWT `user_metadata`
6. Client loads farm IDs via `current_user_farm_ids` RPC
7. Session cached in SQLite `session` table + Supabase SDK secure storage

### Session Management
| Aspect | Status | Evidence |
|--------|--------|----------|
| JWT storage | Supabase SDK secure storage | `supabase_flutter` manages access/refresh tokens |
| Session restore | Reads from SQLite `session` table | `session_dao.dart` — user_json cached |
| Session expiration | **NOT HANDLED** | No `onAuthStateChange` listener, no JWT expiry check |
| Account deactivation | **NOT ENFORCED** | `is_active` not checked on session restore |
| Logout | Partial | Clears `session` table but NOT `offline_*` credentials in `app_settings` |

### Offline Login
- Unsalted SHA-256 of PIN stored in `app_settings` as `offline_pin_hash`
- **P0 ISSUE:** 4-digit PIN + unsalted SHA-256 = brute-forceable in seconds from SQLite file

### Credentials in Code
| Item | Status |
|------|--------|
| Service-role key | **NOT exposed** — only `SUPABASE_ANON_KEY` used |
| Supabase URL | Loaded from `.env` (gitignored) or `--dart-define` |
| Hardcoded secrets | **NONE found** |
| `.env` tracking | **NOT tracked** — verified via `git ls-files` |

## 2. Authorization — Permission Matrix

### RLS Policies (server-enforced)

| Table | Worker | Manager | System Admin |
|-------|--------|---------|--------------|
| `farms` | SELECT own | SELECT own, UPDATE | ALL |
| `users` | SELECT self | SELECT shared-farm, UPDATE self/shared | ALL |
| `user_farms` | SELECT own | SELECT shared, DELETE (admin only) | ALL |
| `flocks` | SELECT/INSERT/UPDATE own farm | ALL own farm | ALL |
| `customers` | SELECT/INSERT own farm | ALL own farm | ALL |
| `egg_production` | SELECT/INSERT/UPDATE own farm | ALL own farm | ALL |
| `mortality` | SELECT/INSERT/UPDATE own farm | ALL own farm | ALL |
| `feed_consumption` | SELECT/INSERT/UPDATE own farm | ALL own farm | ALL |
| `feed_received` | SELECT/INSERT/UPDATE own farm | ALL own farm | ALL |
| `egg_dispatch` | SELECT/INSERT/UPDATE own farm | ALL own farm | ALL |
| `medications` | SELECT/INSERT/UPDATE own farm | ALL own farm | ALL |
| `payments` | **DENIED** | ALL manager-only | ALL |
| `expenses` | **DENIED** | ALL manager-only | ALL |
| `opening_balances` | **DENIED** | ALL manager-only | ALL |
| `inventory_items` | **DENIED** | ALL manager-only | ALL |
| `audit_log` | **DENIED** | SELECT own farm | ALL |
| `medicines_catalog` | SELECT all | ALL | ALL |

### RPC-Level Restrictions (`sync_can_write`)

| Table | Worker | Manager | System Admin |
|-------|--------|---------|--------------|
| egg_production, mortality, feed_consumption, feed_received, medications | INSERT/UPDATE/DELETE | INSERT/UPDATE/DELETE | ALL |
| dispatch_requests | INSERT only | ALL | ALL |
| flocks | INSERT only | ALL | ALL |
| customers | INSERT only | ALL | ALL |
| payments, expenses, inventory_* | **DENIED** | ALL | ALL |

## 3. Critical Security Findings

| # | Severity | Finding | File:Line | Evidence |
|---|----------|---------|-----------|----------|
| 1 | **P0** | **Self-role escalation** — `users_update_self` RLS allows any user to UPDATE their own `role` column to `system_admin`. No trigger or column-level guard prevents this. A worker can PATCH their own role. | `UNIFIED_schema.sql:3182` | RLS policy permits UPDATE on own row; `role` column has no protection |
| 2 | **P0** | **Bootstrap token dead code** — `bootstrap_create_farm_and_manager` receives `p_provision_token` but never verifies it. Both bootstrap RPCs granted to `anon`. Whoever calls first claims system_admin. | `UNIFIED_schema.sql:2374-2473` | Token parameter is unused in function body |
| 3 | **P1** | **4-digit PIN + public pepper + no server-enforced lockout** — `find_user_by_phone` (anon) reveals registration; pepper `madjana$` is in client code + SQL; GoTrue never enforces the lockout counters. 10,000 candidates can be tried against GoTrue directly. | `supabase_auth_datasource.dart:118-127`, `UNIFIED_schema.sql:2374` | Lockout is client-enforced only |
| 4 | **P1** | **Desktop UsersScreen privilege escalation** — manager can create `system_admin` users via role dropdown. No server-side check prevents manager from granting system_admin role. | `apps/desktop/lib/features/users/presentation/users_screen.dart:138-144` | Role dropdown offers all three roles to any manager |
| 5 | **P1** | **Approvals cross-farm data leak** — `approvals_screen.dart` queries `dispatch_requests` with no `farm_id` filter. Any manager sees ALL farms' requests. | `apps/desktop/lib/features/approvals/presentation/approvals_screen.dart:47` | Direct Supabase query without `.eq('farm_id', ...)` |
| 6 | **MEDIUM** | **Stale auth** — no JWT expiry handling, no `onAuthStateChange`, deactivated users stay logged in with cached data. | `auth_provider.dart` (both apps) | No expiry check anywhere |
| 7 | **MEDIUM** | **Incomplete logout** — `offline_*` credentials, `sync_queue`, cached farm data survive logout. Shared device exposes previous user's data. | `auth_repository_impl.dart:221-225` | `logout()` clears only `session` table |
| 8 | **MEDIUM** | **Offline PIN brute-forceable** — unsalted SHA-256 of 4-digit PIN stored in plaintext SQLite. | `auth_repository_impl.dart:67-110` | `sha256(pin)` without salt |
| 9 | **MEDIUM** | **Exception text leaked to UI** — `خطأ غير متوقع: $e` renders raw exception in login error. | `apps/mobile/lib/features/auth/presentation/login_screen.dart:98` | Raw `$e` in snackbar |
| 10 | **LOW** | **Phone enumeration** — `find_user_by_phone` and `check_login_allowed` leak whether a phone is registered. | `supabase_auth_datasource.dart:118-127` | Different error messages for registered vs unregistered |

## 4. SECURITY DEFINER Functions Audit

| Function | Risk | Notes |
|----------|------|-------|
| `is_system_admin()` | **SAFE** | Reads from `users` table, checks `is_active` |
| `current_user_farm_ids()` | **SAFE** | Reads from `user_farms` join table |
| `set_active_farm()` | **SAFE** | Validates membership before update |
| `assert_current_is_manager_of()` | **SAFE** | Raises if not manager/admin |
| `sync_records_batch()` | **REVIEW** | Complex; 300+ lines. Role checks correct but `device_id` never populated |
| `pull_remote_changes()` | **SAFE** | Farm-scoped, role-filtered |
| `bootstrap_create_farm_and_manager()` | **HIGH RISK** | Token not verified; anon grant |
| `create_first_admin()` | **HIGH RISK** | Token wrapper for bootstrap; anon grant |
| `admin_create_user()` | **SAFE** | Requires manager/system_admin |
| `admin_*` (12 functions) | **SAFE** | All require authenticated + role check |
| `throttle_exceeded()` | **SAFE** | Server-side throttle logic (not enforced by GoTrue) |

## 5. Edge Function Security

| Check | Status |
|-------|--------|
| JWT verification | **YES** — `supabaseAdmin.auth.getUser(token)` |
| Service-role isolation | **YES** — service-role used only for `getUser`, not exposed to client |
| User-context client | **YES** — RPC invoked through user-scoped client for proper `auth.uid()` |
| Input validation | **YES** — per-record validation of required fields |
| Batch size limit | **NO** — client limits to 100, server has no limit |
| CORS | Empty `ALLOWED_ORIGINS` — OK for native apps, broken for web |
| Authorization detection | Fragile — Arabic string matching + new `AUTHORIZATION_DENIED:` prefix |
| Idempotency | **YES** — via `idempotency_log` table |
