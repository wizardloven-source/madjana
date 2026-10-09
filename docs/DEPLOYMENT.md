# DEPLOYMENT — Madjana

Operational runbook for the P0 security fix and anything that touches the
running Supabase project. Read §1 before touching production again.

**Source of truth:** `supabase/migrations/` (what to apply) and
`json_output.txt` (what production currently looks like — last refreshed
**before** M8, so it still shows the pre-fix state; see §2.5).

---

## 1. The one live P0: workers can see the money (SEC-002)

`json_output.txt` — a live dump from the Supabase project — shows the **six
financial tables** (`payments`, `expenses`, `revenue`, `opening_balances`,
`inventory_items`, `stock_adjustments`) still gated by
`user_has_farm_access(farm_id)`. That helper returns `true` for **any**
member of `user_farms`, a worker included. In plain words:

> **In production today a worker can read, insert and update the money rows
> of their farm through the REST API.** (`DELETE` is the one verb still
> manager-scoped.)

The fix exists and is fully tested on every branch since M8:
`supabase/migrations/20261002000000_restore_financial_rls.sql`. **It has not
been applied to production yet** — that is what this document is for.

What the fix guarantees (all under test, `p0_financial_rls_guard_test.sql`,
suite 4c — 234 assertions):

- worker: `SELECT`/`INSERT`/`UPDATE`/`DELETE` all rejected, **zero** money
  rows visible;
- manager: full access but **only inside their own farms**;
- `system_admin`: bypasses everything;
- sync (`sync_records_batch`) still pushes as the manager;
- worker operational screens (production, mortality, feed) still work.

---

## 2. Deploy the SEC-002 fix (migration `20261002000000`)

Order matters. Do **not** skip the backup or the precheck. The rollback is
`20261002000001` but it **reopens the hole** — treat it as the emergency
revert only, never as routine.

### 2.0 Pre-flight

- A maintenance window where farm managers can test the financial screens
  immediately after.
- `psql` + `pg_dump` available (Supabase SQL Editor also works for every
  manual step below).
- The operator has the Supabase DB connection string
  (project Settings → Database). It looks like
  `postgresql://postgres.<ref>:<password>@aws-<region>.pooler.supabase.com:6543/postgres`.
- The six financial tables must exist: `20260926000800` or `init.sql` has
  been applied.
- **Anyone with queued offline revenue records in Sync Center:** before
  deploying, check pending worker writes. The old policy let a worker's
  queued revenue row flush; the new one rejects it at the database (the
  app's own revenue screen is manager-gated, so this mainly affects
  third-party clients and stale queues).

### 2.1 Backup

Schema-only is enough for an RLS-only change (the migration touches no
data), but the cheap, safe default is a full backup:

```powershell
# full dump of the whole database (schema + data)
pg_dump "$SUPABASE_DB_URL" -f "backup_sec002_$(Get-Date -Format yyyyMMdd_HHmmss).sql"

# or, minimally, schema-only (covers every policy)
pg_dump --schema-only "$SUPABASE_DB_URL" -f "backup_sec002_schema_$(Get-Date -Format yyyyMMdd_HHmmss).sql"
```

Keep the dump **off** the machine afterward (Supabase dashboard → Database →
Backups also has PITR if enabled). Do not continue without at least the
schema-only dump.

### 2.2 Precheck (read-only — safe to run twice)

The bundled tool makes this one command:

```powershell
python supabase\tools\deploy_sec002_fix.py --connection "$SUPABASE_DB_URL" --precheck-only
```

Expected today: it reports the **WEAK** state on all six tables and that a
fix is needed. If it reports `MANAGER-SCOPED (no fix needed)`, production
was already fixed — stop and investigate rather than apply again.
The precheck also hard-fails if any policy is granted to `anon`/`public`.

### 2.3 Apply

```powershell
# interactive (shows the plan, asks for confirmation)
python supabase\tools\deploy_sec002_fix.py --connection "$SUPABASE_DB_URL" --apply

# unattended (only after you have reviewed the precheck output)
python supabase\tools\deploy_sec002_fix.py --connection "$SUPABASE_DB_URL" --apply --yes
```

The tool: takes the backup (unless `--no-backup`) → runs the migration
(`psql ... -v ON_ERROR_STOP=1 -f 20261002000000_...sql`) → verifies. The
migration itself is transactional (`BEGIN`/`COMMIT` inside), so a failure
mid-apply leaves the database unchanged.

Manual equivalent:

```powershell
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase\migrations\20261002000000_restore_financial_rls.sql
```

### 2.4 Verify

```powershell
python supabase\tools\deploy_sec002_fix.py --connection "$SUPABASE_DB_URL" --verify
```

It asserts, on all six tables: exactly four `TO authenticated` policies each,
every predicate referencing `user_manages_farm` or `system_admin`, and no
`anon`/`public` grant. Plus the behavioural check by hand:

```powershell
# worker token (from app login or a test account) must get [] and 403s
curl "$SUPABASE_URL/rest/v1/payments?select=*" -H "apikey: $ANON" -H "Authorization: Bearer $WORKER_JWT"
#   → HTTP 200, []
curl -X POST "$SUPABASE_URL/rest/v1/expenses" -H "apikey: $ANON" -H "Authorization: Bearer $WORKER_JWT" -d '{"farm_id":"<f>","date":"2026-10-01","category":"other","description":"x","amount":1}'
#   → HTTP 403, "row-level security"

# manager token: the farm's own financial screens still load and save.
```

### 2.5 Post-deploy bookkeeping

- **Regenerate `json_output.txt`** so the official reference matches
  production again (it currently shows the pre-M8 weakened state and will
  claim drift forever otherwise).
- Re-run `python supabase/tools/verify_schema_drift.py` — must stay clean.
- Watch the desktop Sync Center for 30 seconds: `0 failures`.
- Update `docs/DEPLOYMENT.md`'s "last applied" date here when done.

**Last applied to production:** 2026-10-08 — SEC-002 fix `20261002000000_restore_financial_rls.sql`.

On 2026-10-08, after the apply:
- **SEC-002 applied on 2026-10-08** (worker blocked on all six money tables).
- **Drift = 0 after apply** — `verify_schema_drift.py` passes against `json_output.txt`.
- **`json_output.txt` regenerated** from live production (24 RLS policy lines refreshed; 981 lines / 92 policies preserved).

### 2.6 Emergency revert (only if the deploy breaks the app)

```powershell
python supabase\tools\deploy_sec002_fix.py --connection "$SUPABASE_DB_URL" --revert
```

Applies `20261002000001_rollback_financial_rls.sql`. **Warning: this
reopens SEC-002** — a worker can again read/write money. Revert only to
undo an app breakdown, then re-apply §2 as soon as the cause is known.
`p0_financial_rls_guard_test.sql` (4c) will FAIL against the reverted state
by design; that is the alarm, not a test bug.

---

## 3. `customers` is deliberately NOT manager-gated

The M8 scope is exactly the six money tables. `customers` stays as-is
(`SELECT`/`INSERT`/`UPDATE` via `user_has_farm_access`, `DELETE`
manager-scoped) **by product decision**, because:

- workers create and read customers while doing dispatch
  (`dispatch_requests`, dispatch screens);
- manager-gating `customers` would break the worker's core dispatch flow.

Consequences to accept:

- a worker can read and edit their farm's customer contact book (not the
  `total_debt` computation — that is a server-side trigger);
- worker-denied financials does **not** extend to the customer list.

Revisit if a read-only "cashier" or customer-edit separation is ever
requested (SEC-003).

---

## 4. Re-verifying locally

```powershell
# rebuild the scratch DB from shim + init + migrations, then run every suite
python supabase\tests\run_all.py            # expect: ALL GREEN, exit 0
python supabase\tools\verify_migration.py $(Get-ChildItem supabase\migrations -Filter *.sql).FullName
```

The local harness (`supabase/tests/supabase_test_shim.sql`) also reseeds the
`app.v1_grace_until` GUC on every build; that is test-harness-only and has
no effect on production.

---

## 5. DEPLOY W4 (M1-M9: the report/accounting milestone)

W4 is ten forward migrations (M1/M2/M3/M4/M5/M6a/M6b/M6c/M7/M9). M8
(`20261002000000_restore_financial_rls.sql`) is **already deployed** (see
§2, applied 2026-10-08) and is NOT in this list; the tool asserts it is still
in place rather than re-applying it.

The bundled runner `supabase/tools/deploy_w4.py` does the whole sequence
(precheck → apply → verify). Read §5.3 before touching production.

### 5.1 Backup

W4 touches data shapes (M7 converts `revenue.worker_id`, M1-M3 add
flock/cost columns), so the full `public` schema dump is the cheap, safe
default:

```powershell
pg_dump "postgresql://postgres:<PASSWORD>@db.qjcgsvsarxfmplmsujfs.supabase.co:5432/postgres" --schema=public --no-owner --no-acl > "supabase_backup_$(Get-Date -Format yyyyMMdd_HHmmss).sql"
```

Keep the dump off the machine afterward (Supabase dashboard → Database →
Backups also has PITR if enabled). Do not continue without it.

### 5.2 Precheck (read-only — safe to run twice)

```powershell
python supabase\tools\deploy_w4.py --connection "$SUPABASE_DB_URL" --precheck-only
```

Reports the base prerequisites (six financial tables + `user_manages_farm`,
`validate_flock_farm`), then each of the ten migrations as `applied` /
`PENDING`, and the two GUCs (`app.pin_secret` SET of length N; `app.v1_grace_until`
future). Hard-fails if the base is missing — a guard that you pointed the tool
at the wrong database.

### 5.3 Apply

```powershell
# interactive (shows the plan, asks for confirmation)
python supabase\tools\deploy_w4.py --connection "$SUPABASE_DB_URL" --apply --pin-secret "$env:MADJANA_PIN_SECRET"

# unattended (only after you have reviewed the precheck output)
python supabase\tools\deploy_w4.py --connection "$SUPABASE_DB_URL" --apply --yes --pin-secret "$env:MADJANA_PIN_SECRET"
```

Prefer `MADJANA_PIN_SECRET` over `--pin-secret` (the flag is accepted but the
env var keeps the value out of your shell history). The value is **never
echoed** — the tool prints only its length — and it is never committed. New
PIN hashes are derived with `app_password_from_pin_v2` = `'madjana$'||pin||'$'||app.pin_secret`
(see §5.4 for the consequences of deploying without a secret).

The tool: takes the backup (unless `--no-backup`) → applies each **pending**
migration in this order with `psql ... -v ON_ERROR_STOP=1` →

1. `20261003000100_expenses_flock_id.sql` (M1)
2. `20261003000200_stock_adjustments_flock_id.sql` (M2)
3. `20261003000300_medications_cost.sql` (M3)
4. `20261003000400_flock_archived.sql` (M4)
5. `20261003000500_validate_flock_farm_coverage.sql` (M5)
6. `20261003000600_pin_secret.sql` (M6a)
7. `20261003000610_throttle.sql` (M6b)
8. `20261003000620_security_alerts.sql` (M6c)
9. `20261003000700_revenue_worker_id_uuid.sql` (M7)
10. `20261003000900_app_schema_version.sql` (M9)

then sets the two GUCs (unless `--skip-gucs`) →

```sql
ALTER ROLE postgres SET app.pin_secret     = '<secret>';            -- from env, never committed
ALTER ROLE postgres SET app.v1_grace_until = 'now() + 7 days';      -- exact timestamp persisted
```

then runs the hard `--verify`. Every migration is transactional and re-run
safe; a failure mid-apply leaves the database unchanged.

Manual equivalent (interactive apply, one step at a time):

```powershell
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase\migrations\20261003000100_expenses_flock_id.sql
# ... repeat for the nine remaining files in the order above ...
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -c "ALTER ROLE postgres SET app.pin_secret = '$secret'"
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -c "ALTER ROLE postgres SET app.v1_grace_until = '$((Get-Date).ToUniversalTime().AddDays(7))'"
```

### 5.4 What changes and what breaks mid-rollover

- **M7 refuses to apply** while any `revenue.worker_id` is non-UUID; the
  migration itself prechecks and aborts (it is not skipped by `--force`). The
  app has written UUIDs since the sync rework, so production should pass; if
  it aborts, clean the bad rows first, then re-run.
- **M6a after apply:** PIN logins fail **closed** until `app.pin_secret` is
  set — set the GUC **with** the apply (the tool does). Legacy v1 PIN hashes
  stay valid inside the `app.v1_grace_until` window; `record_login_success`
  silently upgrades them to v2. After the grace date a v1 hash raises
  `PIN_VERSION_EXPIRED` and the user needs a PIN reset.
- **M6b/M6c:** login throttling escalates 5→15min, 10→1h, 20→1h + a
  `security_alerts` row; `security_alerts` is readable only by
  `system_admin` (via `get_unresolved_security_alerts()` etc.).
- **M4:** `flocks.status` gains `archived` (one-way via
  `trg_guard_flock_archive`). **M2/M5:** stock adjustments now carry
  `flock_id` with cross-farm validation. **M1:** expenses gain `flock_id`.
  **M3:** medications gain `cost`/`currency`/`inventory_item_id`.
- **M9:** `current_schema_version()` = 1; the client boot gate compares this
  against the local build's `_dbVersion` (see docs/SYNC.md) — old clients see
  "الخادم أحدث — حدّث التطبيق" until the W4 build ships.

### 5.5 Verify

```powershell
python supabase\tools\deploy_w4.py --connection "$SUPABASE_DB_URL" --verify
```

Asserts (read-only): every W4 object present (columns, triggers, RLS policy,
functions, FKs, indexes), `revenue.worker_id` is uuid, all four writers call
v2, `app_schema_version` has exactly version 1 with `anon` unable to EXECUTE,
`app.pin_secret` **set**, `app.v1_grace_until` **future**, and all six
financial tables still manager-scoped (M8 intact). Non-zero exit if anything
is missing.

After regenerating `json_output.txt` (next section) add the static drift
check:

```powershell
python supabase\tools\deploy_w4.py --connection "$SUPABASE_DB_URL" --verify --drift
```

Manual smoke (as installed build):

- worker login (new PIN) → financial screens **rejected**, operational
  screens fine;
- manager login → payments/expenses/revenue load and save;
- Reports → period mode shows opening balances zeroed until the first day of
  the range; cumulative shows `opening_balance` deaths and balances;
- Flock performance → cost breakdown (تكاليف) = flock expenses + priced feed +
  medication-cost + signed adjustments (see docs/ACCOUNTING_RULES.md §6.1).

### 5.6 Post-deploy bookkeeping

- **Regenerate `json_output.txt`** so the official reference matches
  production (it currently stops before W4 and would claim drift forever).
- Re-run `python supabase/tools/verify_schema_drift.py` — must stay clean
  (`--drift` above asserts it).
- Watch the desktop Sync Center for 30 seconds: `0 failures`.
- Update the "last applied" line below.

**Last applied to production:** 2026-10-08 — SEC-002 fix `20261002000000_restore_financial_rls.sql`.
**Last applied to production:** 2026-10-09 — W4 (M1/M2/M3/M4/M5/M6a/M6b/M6c/M7/M9: expenses flock_id, stock_adjustments flock_id + priced rows, medications cost, flock archived, flock/farm coverage, PIN secret v2, login throttle, security alerts, revenue worker_id uuid, app schema version).

On 2026-10-09, after the W4 apply:
- All ten migrations applied in order via `deploy_w4.py --apply` (ten `applied:` lines).
- Both GUCs set: `app.pin_secret` (length only, never echoed) and `app.v1_grace_until` = now + 7 days.
- `deploy_w4.py --verify` → **VERIFY: PASSED**.
- `deploy_w4.py --drift` → **DRIFT: PASSED** (static — the W4 objects are defined in `migrations/`).
- Smoke tests green: worker financials rejected, manager financials work, period/cumulative reports, flock cost breakdown, Sync Center 0 failures.
- **TODO before trusting `json_output.txt` again:** regenerate it from production (¶5.6) — the committed dump still shows `revenue.worker_id` as `text` and has no `app_schema_version`/`security_alerts`, so it stops before W4.

### 5.7 Revert

There is no single rollback file for W4. The migrations are transactional and
idempotent; to back out, restore the §5.1 backup into a scratch database,
extract the pre-W4 shape, and rebuild production from it during a maintenance
window. There is no `--revert` in `deploy_w4.py` on purpose — each M1-M9
change (FKs, RLS, function rewrites, GUCs) would need its own inverse and the
backup is the safer, complete answer.

## 6. DEPLOY W5 (M13-M20: the governance milestone)

W5 is eight forward migrations: M13 record_lock (server-side hard locks +
unlock requests), M14 change_requests (worker requests, synced, manager-only
decision), M15 invoice_audit (egg_dispatch edits/deletes snapshot into
audit_log), M16 role_permissions + user_permissions + has_capability()
(foundation only — no RLS rewrite; W6 consumes it), M17 opening_feed_received_kg
(opening stock derivation), M18 farm_id_audit (farm-move ledger, 13 triggers),
M19 duplicate_guard (fingerprint duplicate denial with a manager-sanctioned
bypass), M20 check_due_payments (آجال reminder notifications).

Everything is additive, idempotent, and re-run safe. No W4 shape, RLS policy,
or GUC is touched. `supabase/tools/deploy_w5.py` applies them in the
operator's declared order and verifies the resulting shape.

### 6.1 Backup

W5 mostly creates new tables and triggers; M17 adds one column. The pg_dump
below is the same safety net as §5.1:

```bash
python supabase/tools/deploy_w5.py --connection "postgresql://user:pass@host:5432/postgres" --backup-dir backups
# does NOT run backup until --apply; see 6.3.
```

### 6.2 Precheck (read-only — safe to run twice)

```bash
python supabase/tools/deploy_w5.py --connection "postgresql://user:pass@host:5432/postgres"
```

Reports the base (W1-W4 + M8) prerequisites and per-milestone applied/pending
state. It flips to "all applied" once every W5 object exists.

### 6.3 Apply

```bash
# interactive (shows the plan, asks for confirmation, runs pg_dump first)
python supabase/tools/deploy_w5.py --connection "postgresql://user:pass@host:5432/postgres" --apply

# unattended (only after you have reviewed the precheck output)
python supabase/tools/deploy_w5.py --connection "postgresql://user:pass@host:5432/postgres" --apply --yes
```

Apply order (EXACT, mirrors `deploy_w5.py --list-migrations`):

```
 1. 20261003001200_record_lock.sql          (M13)
 2. 20261003001300_worker_requests.sql      (M14)
 3. 20261003001400_invoice_audit.sql        (M15)
 4. 20261003001500_role_permissions.sql     (M16)
 5. 20261003001600_opening_feed_received.sql(M17)
 6. 20261003001700_farm_id_audit.sql        (M18)
 7. 20261003001800_duplicate_guard.sql      (M19)
 8. 20261003001900_due_payments.sql         (M20)
```

### 6.4 M20 needs a scheduler — after the apply

`check_due_payments()` scans OPEN آجل payments at four milestones (+3d,
today, -7d, -30d) and inserts one `app_notifications` row per milestone,
keyed so a re-run never duplicates. Nothing calls it on its own unless the
production box has `pg_cron` (the migration schedules `madjana_due_payments`
daily at 06:00 UTC **only if** the extension is present — it is not on plain
PostgreSQL or the local test box).

If `pg_cron` is absent, pick ONE of:
- Supabase: point a daily Edge function timer at `SELECT check_due_payments()`.
- Plain postgres: a cron line `0 6 * * * psql -d <db> -c 'SELECT check_due_payments()'`.

Nothing breaks if it never runs — the آجال reminders simply don't appear. The
+7/+30 auto-due-date on dispatch remains a W6 app decision; this function only
notifies against dates that exist.

### 6.5 Verify

```bash
python supabase/tools/deploy_w5.py --connection "postgresql://user:pass@host:5432/postgres" --verify
```

Asserts (read-only): every W5 object present — the tables
(`record_lock`/`record_unlock_requests`, `change_requests`, `role_permissions`,
`user_permissions`, `farm_id_audit`, `duplicate_guard`), the three SECURITY
DEFINER writers and the fingerprint/has_capability lookups, the 6 lock guards,
13 farm-move triggers, 6 duplicate gates, the 4 change_requests sync triggers,
RLS on every new table, and `anon` denied on the W5 functions.

Behavioural proof (locking works, RLS denies the worker, duplicates are
blocked, a farm move is logged) runs against the local fixtures in the 8
`p0_*` suites of W5 — never against production data.

### 6.6 Post-deploy bookkeeping

- **Regenerate `json_output.txt`** from production after the apply; then
  `python supabase/tools/verify_schema_drift.py` clean. It still stops before
  W4 today.
- M20 reminders: confirm one PAYDUE notification after a test آجل hits a
  milestone (or that a cron/Edge job is scheduled — §6.4).
- Watch the desktop Sync Center for 30 seconds: the new `change_requests`
  table (registry order 210, after `flocks`) must pull with `0 failures`.
- Update the "last applied" line below.

**Last applied to production:** 2026-10-08 — SEC-002 fix `20261002000000_restore_financial_rls.sql`.
**Last applied to production:** 2026-10-09 — W4 (M1/M2/M3/M4/M5/M6a/M6b/M6c/M7/M9: expenses flock_id, stock_adjustments flock_id + priced rows, medications cost, flock archived, flock/farm coverage, PIN secret v2, login throttle, security alerts, revenue worker_id uuid, app schema version).

### 6.7 Revert

Each W5 milestone has its own guarded rollback file (…`01_rollback_*.sql`),
because M13-M20 are individually invertible and the user-level data each one
creates is small. Use them by hand, on purpose — they are never part of the
apply chain. The same §5.7 caveat applies: export the data the rollback would
destroy (unlock requests, change requests, duplicate markers, farm-move
ledger, received feed amounts) before stepping back, and rely on the §6.1
backup as the complete answer.