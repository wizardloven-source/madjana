# YASeen ERP — Security Audit

**Companion to** `FULL_CODE_AUDIT.md`. READ-ONLY; no files modified, no
configuration changed, no credentials tested against a live system.

---

## 1. Summary

YASeen ERP's security model is **genuinely well constructed at the database
layer and genuinely untested at every other layer.** RLS is real, roles are
enforced server-side, privilege escalation is blocked by trigger, and login
throttling exists. That is more than most applications of this size achieve.

The problems are concentrated in three places: the **credential itself** (a
4-digit PIN), the **`anon` grants** on functions that enumerate users, and the
complete **absence of any test** that the authorization model holds.

| Area | Status |
|---|---|
| Row Level Security | **YES** — enabled on all 26 tables, farm-scoped |
| Role model | **PARTIAL** — 3 roles, no cashier/accountant |
| Privilege escalation | **YES** — blocked by trigger + RPC guards |
| Password storage | **YES** — bcrypt, but keyspace is 10⁴ |
| Login throttling | **YES** — configurable window/attempts |
| SQL injection | **NONE FOUND** — PostgREST builder only |
| IDOR / cross-farm | **NONE FOUND** — RLS + validate triggers |
| Secrets in code | **NONE FOUND** — `.env` / `--dart-define` |
| `search_path` hardening | **YES** — all definer functions pinned |
| User enumeration | **YES (P1)** — `find_user_by_phone` granted to `anon` |
| Security tests | **NONE** |
| Session invalidation | **PARTIAL** — `is_active` re-checked per policy, not per request |

---

## 2. Authentication

### Mechanism
Supabase GoTrue (email/password flow) with a synthetic email per user:
```dart
// supabase_auth_datasource.dart:279
String _authEmail(String uid) => '$uid@users.madjana.local';
```
and a static pepper applied client-side before transmission:
```dart
// supabase_auth_datasource.dart:305
String _hashPin(String pin) => 'madjana$' + pin;
```
The server mirrors it:
```sql
-- UNIFIED_schema.sql:2322
extensions.crypt(public.app_password_from_pin(p_pin), extensions.gen_salt('bf'))
```

**Consistency verified:** the client pepper and the server function must match or
no login would ever succeed, and login demonstrably works, so they match.

### Strengths
- bcrypt (`gen_salt('bf')`) — the storage is appropriate.
- `AuthFlowType.pkce` is used, so the authorization code is bound to the client
  and tokens are not exposed to a redirecting attacker.
- **No hardcoded credentials anywhere.** Both `supabase_client.dart` files read
  from `.env` or `--dart-define` and throw a clear error if absent. This is clean
  and better than most production apps.

### SEC-001 — P0 — 4-digit PIN as sole credential
```sql
-- UNIFIED_schema.sql:2300
IF p_pin !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
```

10,000 combinations. The pepper is static in the public repository — it is not a
secret, it only prevents a raw-PIN dictionary attack against a leaked
`auth.users.encrypted_password` hash. It gives no protection against online
guessing.

**Throttling is the only real defence.** `login_throttle` +

---

## 3. Authorization

### The role model
`packages/core/lib/src/constants/enums.dart`:
```dart
enum UserRole { worker, manager, system_admin;
  bool get canViewFinancials => this == manager || this == system_admin;
  bool get canEdit => this == manager || this == system_admin;
}
```

Server-side, role is resolved from the `users` table (never from JWT claims, so a
role change takes effect immediately — correct):
```sql
CREATE OR REPLACE FUNCTION public.is_system_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM public.users
                 WHERE id = auth.uid() AND role = 'system_admin' AND is_active = true);
$$;
```
`is_active = true` is checked here, so deactivating a user revokes admin rights
immediately. Good.

### The four roles from the brief
| Role | Can do | Verified |
|---|---|---|
| **Cashier** | — | **DOES NOT EXIST** |
| **Accountant** | — | **DOES NOT EXIST** |
| **Manager** | full CRUD on own farm, all financial tables | `ensure_manager_policies` |
| **Admin** | cross-farm everything | `is_system_admin()` in every policy |

A farm owner who wants their accountant to see payments but not delete expenses
**cannot express that**. The split is binary: operational-only, or everything.

This is the most significant *authorization* gap, and it is a product gap rather
than a defect — but it is the reason a farm owner would either over-grant (a
manager with delete rights on all money) or under-use the software.

### SEC-002 — P1 — Client-side role checks are decorative
`canViewFinancials` and `canEdit` hide navigation items, but every presentation
file calls repositories directly:
```dart
// dispatch_screen.dart:124
final paymentRepo = ref.read(paymentRepositoryProvider);
```
There is no guard at the call site. RLS is the real boundary — **which is the
correct design** — but two consequences follow:

1. A modified client can attempt any operation. RLS rejects it, so no breach
   occurs, but the rejection is invisible to the user.
2. Because there is **no test** proving RLS rejects a worker, nobody can claim
   with confidence that the boundary holds. It has never been verified.

**Fix:** an integration test that authenticates as a `worker` and asserts
`payments`, `expenses`, `revenue`, and `customers.total_debt` are rejected for
both `SELECT` and `INSERT`. Roughly 40 lines, and the highest-value security
test in the project.

### SEC-003 — P1 — No granular permission model
`ensure_manager_policies(p_table)` is all-or-nothing: `FOR ALL` to managers on
`payments`, `expenses`, `revenue`, `opening_balances`, `inventory_items`. There is
no read-only accountant, no scoped cashier, no per-table permission table.

**Fix (Phase 2):** a `permissions(role, table, operation)` table consulted by a
`can(p_table, p_op)` helper used in every policy. The existing policy-generation
machinery makes this contained — it is the same `EXECUTE format(...)` pattern,
just driven by a table lookup.

---

## 4. Row Level Security

**Enabled on all 26 tables.** Verified table by table; the `CR-1 FIX` comment in
the schema shows the team knew that policies without `ENABLE` are decorative, and
they fixed it.

### Operational tables (worker-accessible, farm-scoped)
`ensure_operational_policies` is applied to `flocks`, `customers`,
`egg_production`, `mortality`, `feed_consumption`, `feed_received`,
`egg_dispatch`, `medications`:
```sql
CREATE POLICY op_select ON %I FOR SELECT TO authenticated
  USING (is_system_admin() OR farm_id = current_user_farm_id());
CREATE POLICY op_update ON %I FOR UPDATE TO authenticated
  USING (...) WITH CHECK (...);
```
`WITH CHECK` on `UPDATE` prevents moving a row to another farm — correct, and
frequently omitted elsewhere.

### Financial tables (manager-only)
`ensure_manager_policies` applied to `payments`, `expenses`, `revenue`,
`opening_balances`, `inventory_items`:
```sql
CREATE POLICY mgr_all ON %I FOR ALL TO authenticated
  USING (is_system_admin() OR current_user_role() = 'manager')
  WITH CHECK (is_system_admin() OR current_user_role() = 'manager');
```

**SEC-004 — P2 — `mgr_all` is not farm-scoped.** Note the contrast: the
operational policies filter on `farm_id = current_user_farm_id()`, but `mgr_all`
filters on **role only**. A `manager` linked to several farms via `user_farms` can
read **and write every financial record in all of them**, including farms where
they are not the active manager.

Whether this is intentional (a manager legitimately overseeing several farms) is

---

## 5. SQL Injection

**No findings.** All database access goes through `SupabaseApi`, a thin wrapper
over the Supabase Dart client's query builder:
```dart
// supabase_revenue_datasource.dart
var query = _api.from('revenue').select().eq('farm_id', farmId);
if (fromDate != null) query = query.gte('date', fromDate.toIso8601String().split('T').first);
```
Parameters are builder arguments, never concatenated. The only raw SQL is in the
**local** SQLite DAOs, where parameters are bound via `whereArgs` and
`rawQuery(sql, [args])` — the standard safe pattern, with no attacker-controlled
path in any case.

**This is clean. Credit where due.**

---

## 6. Secrets and Credentials

| Check | Result |
|---|---|
| Hardcoded Supabase URL/key | **None** — `.env` + `--dart-define` only |
| Hardcoded DB password | **None** — no direct Postgres access from the client |
| API keys in source | **None found** |
| `.env` committed | **No** — covered by `.gitignore` |
| Service-role key in client | **None** — only the anon/publishable key is used |

The auth design deliberately **avoids exposing the service-role key**: user
creation writes directly into `auth.users` from a `SECURITY DEFINER` RPC rather
than via the admin API. That is a deliberate and correct trade-off — it removes a
whole class of key-leak risk, at the cost of the RPC becoming a high-value target
(it is, however, guarded by `assert_current_is_manager_of`).

---

## 7. SEC-005 — P1 — Unauthenticated user enumeration

```sql
CREATE OR REPLACE FUNCTION public.find_user_by_phone(p_phone text)
RETURNS TABLE (id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT u.id::uuid FROM public.users AS u
  WHERE u.phone = p_phone AND u.is_active = true LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.find_user_by_phone(text) TO anon, authenticated;
```

**Callable by `anon` — no credentials at all — returning the internal UUID of any
user whose phone number is registered.**

Two impacts:
1. **Enumeration.** An attacker iterates a phone-number range and learns exactly
   which numbers have accounts — useful for social engineering and for targeting
   the 4-digit PIN attack (SEC-001).
2. **UUID disclosure.** Internal user UUIDs leak, aiding any future IDOR.

The function is consumed by `supabase_auth_datasource.dart` to turn a phone
number into the synthetic auth email before calling `signInWithPassword`. The
design requires the lookup; it does not require it to be anonymous.

**Fix:** revoke from `anon` and route login through a single
`public.login(p_phone, p_pin)` RPC that performs the lookup, applies throttling,
and returns a generic failure — never revealing whether the account exists.
`check_login_allowed` already exists for the throttling half.

Also granted to `anon`, deserving the same review: `app_password_from_pin`,
`app_user_email`, `current_user_role`, `current_user_farm_id`.
`app_user_email(uuid)` is an unauthenticated UUID→email oracle — exactly the
identifier an attacker would pair with SEC-001.

---

## 8. SEC-006 — P2 — Session and deactivation handling

`is_active = true` is enforced inside `is_system_admin()` and
`current_user_role()`, so **every policy re-evaluates it on every query**. A
deactivated user's existing JWT stops working for role-based access within one
request cycle. **This is correct and better than most designs.**

The residual gap is narrow: a **valid but stale JWT** against any table guarded
by a plain GRANT without a role check. Worth a periodic sweep, not urgent.

---

## 9. Findings Summary

| ID | Sev | Finding | Location |
|---|---|---|---|
| SEC-001 | **P0** | 4-digit PIN (10⁴) as sole credential for all financial data | `UNIFIED_schema.sql:2300` |
| SEC-005 | **P1** | `find_user_by_phone` + `app_user_email` granted to `anon` → user enumeration and UUID→email oracle | `UNIFIED_schema.sql` GRANT block |
| SEC-002 | **P1** | Client role checks decorative; RLS untested, so the boundary is unverified | presentation layer + no tests |
| SEC-003 | **P1** | No granular permissions — no cashier/accountant role exists | `ensure_manager_policies` |
| SEC-004 | **P2** | `mgr_all` on financial tables is role-scoped but **not farm-scoped** | `UNIFIED_schema.sql:3157-3165` |
| SEC-006 | **P2** | Verify no table is guarded by GRANT alone without a role check | audit follow-up |
| — | ✅ | No SQL injection | verified |
| — | ✅ | No hardcoded secrets | verified |
| — | ✅ | `search_path` hardened on all definer functions | verified |
| — | ✅ | Privilege escalation blocked by trigger + RPC guards | verified |
| — | ✅ | Throttling infrastructure present and tunable | verified |
| — | ⚠️ | **Zero security tests of any kind** | `packages/data/test` |

---

## 10. What to do, in order

1. **Revoke `anon`** from `find_user_by_phone`, `app_user_email`,
   `app_password_from_pin`, `current_user_role`, `current_user_farm_id`. Route
   login through one RPC. *(Highest security value per line in this document.)*
2. **Write the worker-RLS test.** ~40 lines. Nothing else here is verifiable
   without it.
3. **Raise the PIN to 6 digits** (8 for `system_admin`); key throttling on
   IP + device.
4. **Decide whether `mgr_all` should be farm-scoped**, and if so add
   `farm_id IN (SELECT farm_id FROM user_farms WHERE user_id = auth.uid())`.
5. **Defer** the granular permission model to Phase 2 — a product decision, not
   a defect.

not determinable from code, but it should be a deliberate decision rather than a
default. At minimum it should be
`farm_id IN (SELECT farm_id FROM user_farms WHERE user_id = auth.uid())`.

### Inventory
`inventory_transactions` gets a bespoke policy that correctly scopes by the
parent item's farm — good, because the table has no `farm_id` of its own.
`stock_adjustments` is farm-scoped and manager-only.

### Customers
`ensure_operational_policies` special-cases `customers` to allow `is_global` rows
across farms — appropriate for a shared customer list, and `DELETE` correctly
requires manager.

### Definer-function privileges
`SECURITY DEFINER SET search_path = public, pg_temp` is applied to every definer
function. This prevents search-path hijacking and is **correct hardening** — one
of the more commonly missed items, and it is right here.

`record_login_failure` + `check_login_allowed` + `throttle_exceeded`, with
`throttle_max_attempts()` and `throttle_window_seconds()` as tunable functions.
The design is sound. Two questions I could not settle statically, which you should
verify directly in the database:

1. Is the throttle keyed on **phone number only**, or also on IP/device? Phone
   only means parallel guessing from multiple IPs is unthrottled.
2. After a lockout expires, is the counter fully reset, or is there exponential
   backoff? A fixed window means 10,000 attempts over N windows.

**Fix:** 6 digits minimum, 8 for `system_admin`, plus IP+device keying. See
`ACCOUNTING_INTEGRITY_AUDIT.md` ACC-004.
