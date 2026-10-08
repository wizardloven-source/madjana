# SECURITY — Database write guards

The schema protects a row in two independent layers, and they answer
different questions:

| Layer | Question | Where |
|---|---|---|
| **RLS policies** | may this *user* read/write rows of this *farm*? | per-table policies |
| **Write guards (this file)** | is the *row itself* internally consistent, no matter who wrote it? | `BEFORE` triggers |

A `service_role` or superuser migration bypasses RLS by design; it does
not bypass a trigger. A forged row that slips past RLS (bug, migration,
direct SQL) is still refused by the guards below.

---

## 1. Cross-farm write guard — `validate_flock_farm()`

Canonical body: `init.sql` §13, restated verbatim by
`migrations/20261003000500_validate_flock_farm_coverage.sql`.

```
NEW.flock_id IS NULL          -> pass    (farm-level row: salaries, overhead)
flock does not exist          -> RAISE   'الدجاجة غير موجودة: %'
flock.farm_id != NEW.farm_id  -> RAISE   'الدجاجة لا تنتمي لهذه المزرعة'
```

It runs `BEFORE INSERT OR UPDATE`, so both a forged insert and an UPDATE
that re-links a row to another farm's flock are refused. The function is
`SECURITY DEFINER … SET search_path = public, pg_temp` so the lookup
cannot be redirected by a hostile `search_path`.

| Table | Trigger | Owner (introduced by) | Its rollback |
|---|---|---|---|
| egg_production | `trg_validate_flock_farm` | `init.sql` §13 | — (base schema) |
| mortality | `trg_validate_flock_mortality` | `init.sql` §13 | — (base schema) |
| feed_consumption | `trg_validate_flock_feed` | `init.sql` §13 | — (base schema) |
| medications | `trg_validate_flock_med` | `init.sql` §13 | — (base schema) |
| opening_balances | `trg_validate_flock_ob` | `init.sql` §13 | — (base schema) |
| flock_movements | `trg_validate_flock_movements` | `20260927000000` (W0.1) | `20260927000001` |
| egg_dispatch | `trg_validate_flock_dispatch` | `20260927000000` (W0.1) | `20260927000001` |
| feed_received | `trg_validate_flock_feed_recv` | `20260927000000` (W0.1) | `20260927000001` |
| expenses | `trg_validate_flock_expenses` | `20261003000100` (M1) | `20261003000101` |
| stock_adjustments | `trg_validate_flock_sa` | `20261003000500` (M5) | `20261003000501` |

**`stock_adjustments` was the hole M5 closed:** M2 gave the table a
`flock_id` column but no guard, so a stock adjustment could name another
farm's flock while every other table refused the same lie.

---

## 2. NOT NULL write guard — `require_farm_id()`

`BEFORE INSERT OR UPDATE` on five transaction tables, raising
`farm_id is required (table %)` when `NEW.farm_id IS NULL`:

| Table | Trigger (all owned by M5 `20261003000500`) |
|---|---|
| egg_dispatch | `trg_require_farm_id` |
| feed_received | `trg_require_farm_id` |
| stock_adjustments | `trg_require_farm_id` |
| expenses | `trg_require_farm_id` |
| medications | `trg_require_farm_id` |

This is belt-and-braces: all five columns are `NOT NULL` at the DDL
level already. The trigger gives one clear, table-named error message
and keeps the guarantee if the column constraint were ever dropped.
Empirically the trigger fires **before** the `NOT NULL` check and before
the RLS `WITH CHECK` (verified by the test suite asserting the message).

---

## 3. Healing note — the first version of M5 was wrong

The first commit of `20261003000500` (in the W1 push) **replaced**
`validate_flock_farm()` with a flock-*status* checker and attached a
stray trigger to `flocks`. Had it reached production it would have
silently broken the cross-farm guard on every table in §1.

The current file undoes all of it and proves the undo in its own
verification block:

- restates the canonical cross-farm body (fails if `%لا تنتمي%` is gone);
- `DROP TRIGGER IF EXISTS trg_validate_flock_farm ON public.flocks`
  (fails if the stray trigger survives);
- `DROP INDEX IF EXISTS public.idx_flocks_active`.

Re-applying the file heals any database that ran the broken version.
Nothing had reached production: this project has no numbered-migration
lineage — applies are manual — and CI rebuilds its database from
scratch on every run.

---

## 4. Rollback ownership (scope guard)

A rollback drops **only what its own migration introduced**:

| Rollback file | Drops | Deliberately keeps |
|---|---|---|
| `20261003000501_rollback_validate_flock_farm_coverage.sql` | `trg_validate_flock_sa`, 5 × `trg_require_farm_id`, `require_farm_id()`, stray flocks trigger/index | `trg_validate_flock_dispatch`/`_feed_recv` (W0.1), `trg_validate_flock_expenses` (M1), `trg_validate_flock_med` (init) — guards that predate M5 belong to their own rollbacks |

---

## 5. Tests

`supabase/tests/p0_validate_flock_farm_coverage_test.sql` — **33
assertions**, inside `BEGIN/ROLLBACK`:

- 10 structural (every trigger installed);
- 5 cross-farm flock rejected (one per guarded table), message asserted;
- 5 `farm_id NULL` rejected, message asserted;
- 5 `flock_id NULL` accepted;
- same-farm accepted, nonexistent flock rejected, cross-farm UPDATE rejected;
- guard body intact, no stray trigger on `flocks`;
- the migration's DDL re-run idempotently.

Wired as suite **4h** in `supabase/tests/run_all.py`, so it runs in both
CI workflows (`db_migration_test` and `P0 Financial RLS Guard`).

---

## 6. PIN → password v2 (server-side secret) — `app_password_from_pin_v2()`

**Why.** v1 derives `'madjana$' || pin` in a public SQL function
(`app_password_from_pin`, `init.sql`). The derivation is deterministic and
client-visible, so anyone who obtains a bcrypt hash can brute-force the whole
10,000-pin space offline at leisure.

**v2** (M6a `20261003000600`, body restated by the migration):

```
'madjana$' || pin || '$' || <app.pin_secret>
```

- `app.pin_secret` is a **server-only GUC**: ops sets it via
  `ALTER ROLE postgres SET app.pin_secret = '…'` (works in Supabase and
  self-hosted). On self-hosted without a superuser, `ALTER DATABASE <db> SET
  app.pin_secret = '…'` is the fallback. It is never stored in the repo or
  written by any migration.
- `app_password_from_pin_v2(text)` is `STABLE SECURITY DEFINER
  SET search_path = public, pg_temp` and **REVOKEd from PUBLIC, anon and
  authenticated** — it is a PIN oracle and is never exposed to any API role.
- It **RAISEs** (`PIN_SECRET_NOT_CONFIGURED`) when `app.pin_secret` is unset
  or empty: writers and logins fail closed until ops supplies the secret.

## 7. Grace period and the server-side upgrade — `record_login_success(uuid, text)`

M6a replaces `record_login_success(uuid)` with `(uuid, text)`: the server
receives the **4-digit PIN only**, validates it against the stored hash, and
writes the v2 hash itself. The client never computes a password derivation.

| Stored hash | v2 match | v1 match within `app.v1_grace_until` | v1 match after grace / GUC unset | no match |
|---|---|---|---|---|
| next login | nothing to do | **upgraded to v2** in `auth.users` + `public.users` | `PIN_VERSION_EXPIRED` refused | `INVALID_PIN` refused |

- `app.v1_grace_until` is auto-seeded to `NOW() + 7 days` when unset
  (session value; the migration also persists it with
  `ALTER ROLE postgres SET` — the form that works from the Supabase SQL
  Editor — falling back to `ALTER DATABASE … SET` on self-hosted). See §8.
- If `app.v1_grace_until` is **unset**, v1 is refused immediately (fail
  closed). Ops that want a real 7-day window must set it explicitly.
- On success the function also resets `failed_attempts = 0` and
  `locked_until = NULL`, preserving the old `record_login_success` behaviour.
- Granted to **`authenticated` only** (previously `anon` + `authenticated`):
  anon must never reach a PIN oracle.

**The four writers store v2 from M6a onward** (rewritten in place, their
bodies call `app_password_from_pin_v2`):

| Function | Caller must be |
|---|---|
| `admin_create_user(text,text,text,text,text)` | sysadmin or that farm's manager |
| `create_farm_with_manager(name,loc,manager,phone,pin)` | sysadmin |
| `admin_reset_pin(p_uid, new_pin)` | sysadmin or that farm's manager |
| `bootstrap_create_farm_and_manager(…, provision_token)` | provision token |

## 8. M6a rollout notes and rollback guard

**Setting the GUCs — the ALTER ROLE decision:**

`ALTER DATABASE … SET` works on self-hosted PostgreSQL but is rejected from
the Supabase SQL Editor, so the primary form is **ALTER ROLE postgres**, which
applies to every future session that connects as `postgres` (this is also the
session whose SECURITY DEFINER functions read the secret):

| Where | `app.pin_secret` (ops, before/with M6a) | `app.v1_grace_until` (M6a persists it) |
|---|---|---|
| Supabase (SQL Editor) | `ALTER ROLE postgres SET app.pin_secret = '<random string>';` | auto-seeded by M6a via `ALTER ROLE postgres`; manually: `ALTER ROLE postgres SET app.v1_grace_until = '<date+7d>';` |
| Self-hosted (DB owner) | `ALTER ROLE postgres SET app.pin_secret = '<random string>';` — fallback `ALTER DATABASE <db> SET app.pin_secret = '<random string>';` | auto-seeded; fallback `ALTER DATABASE <db> SET app.v1_grace_until = '<date+7d>';` |

The migration auto-seeds `app.v1_grace_until` to `NOW() + 7 days` and tries
`ALTER ROLE postgres` first, then `ALTER DATABASE`. If both fail it leaves the
session value only and raises a NOTICE telling ops to persist it — otherwise
v1 hashes are refused immediately after deploy (the fail-closed default). The
random `app.pin_secret` itself is never written by any migration or placed in
the repo.

**Deploy order** (avoid a login outage):

1. `ALTER ROLE postgres SET app.pin_secret = '<random string>';` — before or
   with M6a. Until then, writers and `record_login_success` fail closed.
2. If a real 7-day grace window is wanted and the auto-seed is not enough:
   `ALTER ROLE postgres SET app.v1_grace_until = '<deploy_date + 7 days>';`
   (the migration's auto-seed already covers the common case). If this is not
   set, v1 hashes are refused immediately after deploy — the fail-closed
   default.
3. Deploy M6a, then update the client to call
   `record_login_success(p_uid, p_pin)` with the raw PIN and to stop deriving
   `'madjana$' || pin` locally for GoTrue.

**Client caveat.** The current client signs into GoTrue with the locally
derived v1 password (`'madjana$' || pin`, `supabase_auth_datasource.dart`). A
user whose hash has been upgraded to v2 can no longer log in with that
candidate until the client is updated. Ship the client change with (or
before) M6a, and keep the grace window for stragglers.

**OP risk if you must roll M6a back**
(`20261003000601_rollback_pin_secret.sql`): bcrypt hashes carry no scheme
marker, so the rollback guards itself by trying every one of the 10,000 pins
against each stored hash. A hash that matches no v1 candidate would be a
stranded v2-only user, and the rollback **refuses** rather than strand them
(it caps at 500 hashes; a `statement_timeout` aborts the transaction before
any change — the safe direction). After a rollback, ops must also clear the
GUCs: `ALTER ROLE postgres RESET app.pin_secret; ALTER ROLE postgres RESET
app.v1_grace_until;` (fallback: `ALTER DATABASE <db> RESET …`). Manual
rollback is required for a DB that has let users upgrade for more than the
window.

**Opens with M6b/M6c:** M6b implements server-side per-key login throttling
with an escalating lock ladder (this hub). M6c adds the `security_alerts`
admin surface (RLS, grants, and the UI/ops tooling on top of the store that
M6b already writes to).

## 9. Login throttling (M6b)

`20261003000610_throttle.sql` closes two holes in the legacy throttle:

1. **Client-supplied bounds removed.** The old `throttle_exceeded(p_key,
   p_max, p_window_seconds)` let the caller set both the threshold and the
   window: `p_max = 0` turned a single request into an instant lock on any
   guessable key (a self-inflicted DoS), and a huge `p_max` silently disabled
   the throttle. The new `throttle_exceeded(text)` reads its bounds **only**
   from `throttle_max_hits()` (`10`) and `throttle_window_seconds()` (`60`),
   so an attacker's arguments cannot weaken or weaponise it. The old 3-arg
   form is dropped. It is `SECURITY DEFINER`, revoked from `PUBLIC`, anon and
   granted to `authenticated` only (a fresh function would EXEC to PUBLIC by
   default — M6b revokes explicitly).
2. **Phone/IP-aware failure tracking.** `record_login_failure(p_phone, p_ip)`
   (replaces `record_login_failure(phone)`) records **every** failure under
   two composite keys in `login_throttle`: `'phone:' || p_phone` and
   `'ip:' || p_ip`. `p_ip` may be `NULL` (fall back to the phone key alone);
   `p_phone` may be `NULL` (IP-only attacks). It returns jsonb with the
   account counter shape intact:
   `{locked, lock_seconds, attempts_left, phone_hits, ip_hits, alert}`.

**Escalating ladder** — applied per key, on top of the unchanged
5-failure account counter:

| login_throttle hits (single key) | Result                                  |
|-----------------------------------|-----------------------------------------|
| 1–4                               | watched, no lock                        |
| 5–9                               | 15-minute lock (`900s`)                 |
| 10–19                             | 1-hour lock (`3600s`)                   |
| ≥ 20                              | 1-hour lock **and** a `login_throttle` security alert (`record_security_alert`, severity `high`, meta carries `key`/`hits` and the phone or IP) |

The alert lands in the `security_alerts` store that M6b creates in minimal
form (M6c adds RLS + grants + admin tooling). `record_security_alert` is an
internal `SECURITY DEFINER` writer — not granted to any API role. At exactly
20 hits an alert is emitted per crossing key.

**Grants summary:**

| function                         | PUBLIC | anon  | authenticated |
|----------------------------------|--------|-------|---------------|
| `throttle_exceeded(text)`        | –      | –     | ✓             |
| `record_login_failure(text,text)`| –      | ✓     | ✓             |
| `record_security_alert(...)`     | –      | –     | –             |

`record_login_failure` stays callable by anon because it runs **before** a
session exists; `throttle_exceeded` does not need to (authenticated only).

**Client caveat.** After M6b deploys, the client must pass the IP (and the
phone) to `record_login_failure` — the old single-argument call stops
resolving (`supabase_auth_datasource.dart:176`). Ship the client change with
(or before) M6b; the 3-arg `throttle_exceeded` call also disappears.

**Rollback.** `20261003000611_rollback_throttle.sql` restores the original
`throttle_exceeded(text,int,int)` and `record_login_failure(phone)` bodies
with their original grants, and drops the M6b-only objects
(`record_security_alert`, `security_alerts`). It is **guarded**: the rollback
refuses while `security_alerts` still holds any alert row — review those
20+ hit bursts or empty the table before rolling back (a missing/empty store
rolls back automatically; the file is idempotent).

## 10. security_alerts admin surface (M6c)

M6b created `security_alerts` minimal (no RLS, no grants) so the 20-hit
throttle ladder had somewhere to record escalations — readable by nothing in
the app. M6c gives a system admin the sanctioned surface and locks everyone
else out **at the row level**, not just at the grant level:

**RLS.** `security_alerts` has `ROW LEVEL SECURITY` enabled with exactly one
`FOR ALL` policy (`security_alerts_admin_all`) whose `USING`/`WITH CHECK` is
`is_system_admin()` — nothing else. No worker policy, no manager policy:

```
USING (is_system_admin()) WITH CHECK (is_system_admin())
```

**Grants.** Table: `REVOKE ALL` from `PUBLIC`, `anon`, `authenticated`, then
`GRANT SELECT, INSERT, UPDATE TO authenticated`. Because RLS still filters,
an `authenticated` session that is **not** a system admin sees zero rows and
its INSERTs are refused even though the GRANT exists — the grant is just the
passage rights, the policy is the lock.

**Admin surface (all `SECURITY DEFINER`, pinned `search_path`, granted to
`authenticated` only, each re-gates the caller with `is_system_admin()`):**

| function | contract |
|---|---|
| `get_unresolved_security_alerts()` | returns the open cases (`resolved_at IS NULL`), newest first (`ORDER BY created_at DESC`) |
| `acknowledge_security_alert(uuid)` | stamps `acknowledged_at`/`acknowledged_by` (`auth.uid()`), does **not** resolve |
| `resolve_security_alert(uuid)` | stamps `resolved_at`/`resolved_by` (`auth.uid()`) |

`acknowledge_security_alert` and `resolve_security_alert` write the audit
columns M6c adds: `acknowledged_at`, `acknowledged_by`, `resolved_at`,
`resolved_by`. A second `SECURITY DEFINER` gate inside every function means a
grant misconfiguration (or a leaked `authenticated` role) never escalates to
admin reads.

The M6c migration (`20261003000620_security_alerts.sql`) does **not** recreate
the table and does **not** recreate `record_security_alert` — those are M6b
objects; M6c only ALTERs the table (columns + RLS) and installs the policy,
grants and the three functions.

**Rollback.** `20261003000621_rollback_security_alerts.sql` is **guarded**: it
refuses while `security_alerts` holds any alert row (review/empty it first),
then drops the three functions, drops `security_alerts_admin_all`, disables
RLS, revokes the authenticated grants, and drops the four audit columns —
restoring the M6b shape (table + `record_security_alert` intact).

**Client caveat.** The admin surface is exposed as database functions only;
there is **no** SQL-linter/UI yet. The desktop admin surface work item (W5)
will build on `get_unresolved_security_alerts()` /
`acknowledge_security_alert(uuid)` / `resolve_security_alert(uuid)`.

## 11. Tests

`supabase/tests/p0_pin_secret_test.sql` — **30 assertions**, inside
`BEGIN/ROLLBACK`, wired as suite **4i** in `supabase/tests/run_all.py`:

- 4 structural on the v2 derivation (STABLE, SECURITY DEFINER, pinned
  search_path, exists);
- 2 that v2 is revoked from anon/authenticated;
- 4 on `record_login_success` signature + grants;
- 2 that the four writers target v2 and none target v1;
- v2 value derivation, and v2 RAISE when `app.pin_secret` is unset;
- v1-within-grace login upgrades both hashes; wrong PIN leaves the hash
  untouched; v1 after grace refused and not upgraded; v1 with no grace GUC
  refused (fail closed);
- v2 login succeeds and resets the lockout counters; wrong v2 PIN refused
  without downgrade;
- `admin_reset_pin` stores v2 end-to-end;
- the migration's DDL re-runs idempotently.

`supabase/tests/p0_deploy_m6_test.sql` — **deploy simulation, suite 4j** in
`supabase/tests/run_all.py`. It runs against the database
`build_test_db.py` recreated and re-migrated from scratch, so it is the
fresh-deploy simulation for the whole M6 chain:

- M6a: `app.pin_secret` is configured (inherited via `ALTER ROLE postgres`);
- M6a: `app.v1_grace_until` is set and ≈ `NOW() + 7 days`; M6a objects present;
- M6a: `record_login_success` upgrades a legacy v1 PIN on the deployed schema,
  the upgraded user still logs in (v2), and a wrong PIN is rejected
  (`INVALID_PIN`);
- M6b: only `throttle_exceeded(text)` exists (no client-supplied bounds), anon
  is blocked, `record_login_failure(text,text)` is ready with anon pre-login
  access, `security_alerts` exists;
- M6b: the ladder works on the fresh build — 5 failures → 900s lock, 20 → an
  `alert` fired and a row persisted in `security_alerts`.

`supabase/tests/p0_throttle_test.sql` — **M6b throttle suite, 4k**: structural
(signature pairs, the 3-arg DoS call fails to resolve), ACL contract (PUBLIC/
anon/PUBLIC/authenticated matrix for all three functions), behavioural
(number-only `phone:` key, IP-only `ip:` key, server bounds lock at 10,
escalation 5→900s / 10→3600s / 20→alert), account-counter preservation on a
known phone, `security_alerts` row persistence, idempotent re-run of the DDL,
and the guarded rollback (refuses while alerts exist, then restores the
original functions and drops the M6b objects).

`supabase/tests/p0_security_alerts_rls_test.sql` — **M6c RLS + admin surface
suite, 4l**:

- structural + ACL: RLS on, the one admin-only policy gated on
  `is_system_admin()`, anon has no table privileges, authenticated has the
  SELECT/INSERT/UPDATE trio (RLS still filters), the three functions exist and
  are revoked from anon;
- RLS behavioural: a system admin session inserts/sees rows, a worker and a
  manager session both see zero rows and have INSERT refused;
- admin surface: worker and manager are gated out of all three functions,
  sysadmin gets unresolved-only newest-first, `acknowledge_security_alert`
  stamps `acknowledged_at/by` without resolving, `resolve_security_alert`
  stamps `resolved_at/by` and removes the row from the open list;
- the migration's DDL re-runs idempotently;
- the guarded rollback refuses while alerts are on file, and once empty
  restores the M6b shape (functions gone, policy gone, RLS off, grants
  revoked, audit columns dropped).
