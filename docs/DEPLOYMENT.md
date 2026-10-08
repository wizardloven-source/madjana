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

**Last applied to production:** _not yet_.

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