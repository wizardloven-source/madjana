## 4. Updating the reference

Only possible once a local or remote Postgres is reachable. Today neither
`psql` nor Docker is installed on this machine, so the dump is frozen.

```powershell
# 1. Install the Supabase CLI (already present) and Docker Desktop.

# 2. Link the project
supabase link --project-ref <ref>          # ref: supabase\.temp\project-ref

# 3. Regenerate the dump from the live database
supabase db dump --data-only --schema public > json_output.txt

# Or, against a local stack:
supabase start
supabase db dump --local --schema public > json_output.txt
```

The dump must keep the exact line format the checker expects — one JSON
object per Markdown table row:

```
| {"type":"Table","table_name":"flocks","column_name":"id","data_type":"uuid"}   |   |
```

After regenerating, re-run `verify_schema_drift.py` and commit the new
`json_output.txt` in the same commit as whatever migration caused the
change. A dump that does not match the migrations is itself drift.

---

## 5. Known drift

State as of **2026-09-27** (Wave W0). All items are closed or owned.

| # | Item | Status |
|---|---|---|
| 1 | `flock_movements` absent from every repo file | **CLOSED** — `migrations/20260927000000_add_missing_tables.sql` |
| 2 | `sync_table_registry` absent from every repo file | **CLOSED** — same migration |
| 3 | 4 x `.bak`/`.orig` files inside `migrations/` | **CLOSED** — moved to `supabase/_archive/` |
| 4 | `schema_production.sql` missing the two tables | **PATCHED** — temporary block at end of file, flagged for regeneration |

### Note on item 4

`schema_production.sql` is a **generated snapshot** and must not be edited
by hand. It was patched temporarily, under a loud `TEMPORARY DRIFT PATCH`
banner, purely so the snapshot stops contradicting production. The moment
Docker is available, regenerate the whole file with `supabase db dump` and
delete the banner block.

### ⚠ TESTING STATUS — read before trusting W0.1

**W0.1 has NOT been executed against a live database.** No Postgres and
no Docker are installed on the development machine, and no database
credentials are present in `.env` (only `SUPABASE_URL` and
`SUPABASE_ANON_KEY`). The migration has been checked structurally —
balanced `BEGIN`/`COMMIT`, matched `$$` delimiters, no destructive
statements, idempotency guards on every object — but **no SQL has run**.

It is **not yet proven** that:

- the `IF NOT EXISTS` guards behave correctly against a table that already
  exists in production with a different shape;
- `sync_table_registry` seeds cleanly against the real contents;
- the verification block passes on real data.

Run it against a scratch project first:

```powershell
supabase link --project-ref <scratch-ref>
supabase db push --dry-run      # read the plan
supabase db push                # then apply to the scratch project
```

A CI job (`db_migration_test`) now runs apply → rollback → re-apply against
a real Postgres on every push. Its result on this migration is the first
genuine execution evidence, and it has not been observed yet.

### What this drift was actually costing

`flock_movements` and `sync_table_registry` are both **load-bearing for
sync**. `sync_table_registry` is the ordered allowlist the sync engine
reads to decide what may move; a table missing from it never syncs. A
database rebuilt from the repo files would therefore drop both, and data
would stop syncing — silently, with no error anywhere. This is the leading
candidate for the long-standing "sync fails, usually with no message"
complaint.

---

## 6. Conventions to follow in any new migration

Taken from what production actually does, not from what a style guide
would prefer.

**Naming**
- Policies: `<table>_<op>` where op is `read`/`insert`/`update`/`delete`.
  Exception: `flock_movements` uses `select` — production is the reference.
- Manager-scoped: `mgr_all`, `mgr_tx`. Admin: `admin_write`.
- Triggers: `trg_<verb>_<table>`.
- Functions: `snake_case`, no prefix.

**Every synced table carries**
`id uuid PK`, `farm_id uuid FK farms ON DELETE RESTRICT`, `version bigint`,
`sync_status text`, `created_at`/`updated_at`/`deleted_at timestamptz`,
a `trg_populate_sync` trigger, a `trg_sync_tombstone_*` trigger, RLS
enabled, and `sync_status` constrained to
`pending|synced|failed|processing|conflict`.

**Every migration must be**
- idempotent (`IF NOT EXISTS`, `DROP ... IF EXISTS`, `CREATE OR REPLACE`)
- wrapped in `BEGIN` / `COMMIT` with `SET LOCAL lock_timeout`
- followed by a verification block that raises on failure
- free of destructive changes to existing data

---

## 7. Change log

| Date | Change |
|---|---|
| 2026-09-27 | Document created (W0.4). Drift checker added. Items 1-4 closed. |
| 2026-09-27 | Added rollback `20260927000001_rollback_missing_tables.sql`, the `guard_worker_same_farm()` trigger, and the `db_migration_test` CI job. W0.1 marked untested. |
| 2026-10-03 | M7: `revenue.worker_id` TEXT→UUID with FK `revenue_worker_id_fkey` (ON DELETE SET NULL) and `idx_revenue_worker`. Suite **4m**. Guards and rollback in `20261003000700/701`. |
| 2026-10-03 | M8: financial RLS is manager-only again on payments/expenses/revenue/opening_balances/inventory_items/stock_adjustments. Forward `20261002000000`, rollback `20261002000001`, guard suite **4c**. |
| 2026-10-08 | M9: client/server schema-version marker. Table `app_schema_version` + `current_schema_version()` RPC (SECURITY DEFINER, STABLE, `SET search_path = public`), read-open RLS by design, **anon excluded**. Metadata-only — deliberately not in `sync_table_registry`. Local DB v29→30 + `local_schema_meta`. Forward `20261003000900`, rollback `20261003000901`, suite **4n**. Full contract in `docs/SYNC.md`. |
| 2026-10-09 | M11: report mode (فترة/تراكمي) gates `opening_balances` contributions in analytics. No schema change — mapping in `docs/REPORTS.md`. |
| 2026-10-09 | M12: `FlockCostCalculator` implements the §6 flock-cost formula in Dart (`estimatedCost` → `costBreakdown` on `FlockPerformance`). No schema change — reuses `expenses.flock_id` (M1), `stock_adjustments.unit_price` (M2), `medications.cost`/`inventory_item_id` (M3). |
| 2026-10-09 | W5-M13: `record_lock` + `record_unlock_requests` + `assert_record_not_locked()` (SECURITY DEFINER, BEFORE UPDATE OR DELETE on payments/expenses/revenue/egg_production/mortality/feed_consumption). Control tables — **not** in `sync_table_registry`. FKs never CASCADE. |
| 2026-10-09 | W5-M14: `change_requests` (worker requests, manager decision) — **synced** (registry sort_order 210, after `flocks`), 4 sync triggers, RLS: read farm members, insert own only, update/delete manager/admin. |
| 2026-10-09 | W5-M15: `trg_audit_invoice()` (SECURITY DEFINER) + 2 triggers snapshot egg_dispatch invoice edits/deletes into existing `audit_log`. No new columns/tables. |
| 2026-10-09 | W5-M16: `role_permissions` + `user_permissions` + `has_capability(uuid,text,uuid)` — capability foundation (allow/deny, admin-only RLS, deny-by-default). No RLS rewrite; W6 adds the consuming policies. |
| 2026-10-09 | W5-M17: `opening_balances.opening_feed_received_kg numeric(19,4)` + non-negative CHECK, nullable ("unknown" ≠ "zero"). Opening stock is derived `received − consumed`; synced ride-along, no registry change. |
| 2026-10-09 | W5-M18: `farm_id_audit` ledger + `trg_farm_id_audit()` (SECURITY DEFINER) + 13 BEFORE UPDATE OF farm_id triggers. Server-side ledger, not synced. |
| 2026-10-09 | W5-M19: `duplicate_guard` + `dup_fingerprint(text,jsonb)` + `trg_duplicate_guard()` + 6 BEFORE INSERT gates (expenses/egg_production/mortality/feed_consumption/feed_received/payments). Partial unique index `uq_duplicate_guard_unblocked`; manager `blocked=true` bypass. |
| 2026-10-09 | W5-M20: `check_due_payments()` (SECURITY DEFINER) — آجال reminders at +3d/today/−7d/−30d into `app_notifications`, idempotent per milestone (`PAYDUE:<ms>:<id>` key). pg_cron job optional (guarded DO). |

# SCHEMA_REFERENCE — Madjana

The single source of truth for the shape of the database, and the rules
for changing it.

---

## 1. The reference

**`json_output.txt` (repository root) is the official reference.**

It is a live dump taken from the running Supabase project, not a file
written by hand. As of the last update it contains:

| Object | Count |
|---|---|
| Tables | 30 |
| RLS policies | 92 |
| Triggers (excl. `RI_ConstraintTrigger_*`) | 42 |
| Functions | 72 |
| Storage buckets | 1 (`farm-images`) |
| Constraints | 89 |

`RI_ConstraintTrigger_*` entries are internal rows PostgreSQL generates for
every FOREIGN KEY. They are never written by hand and are excluded from
all counts and comparisons.

### Why a dump and not the migration files

`supabase/migrations/` is the authoritative record of *what we did*. It is
not a description of *what is there*: it only grows, it is never pruned,
and a migration that fails halfway leaves the files claiming more than the
database contains. `json_output.txt` answers the second question.

---

## 2. The rule

> **Every migration is reviewed against `json_output.txt` first.**

Before writing any migration, open the dump and confirm:

1. The table does **not** already exist (no duplicate definition).
2. No function with that name already exists.
3. No trigger with that name already exists.
4. The column does not already exist with a different type.
5. The RLS predicate in the dump matches what you intend to write.

If any of these collide, **stop and report the conflict** rather than
adding a second definition. Two definitions of the same thing is how
`sync_conflicts`, `farm-images` and the currency columns drifted in the
first place.

When the dump disagrees with what the code needs, the dump wins for
*structure* and the code wins for *values*. Fix the code, or write a
migration that moves the database to the code — never assume the file is
what the server has.

---

## 3. Running the drift check

```powershell
python supabase\tools\verify_schema_drift.py
```

Exit code `0` = no drift, `1` = drift (do not deploy). Add `--json` for
machine-readable output suitable for CI.

It is a **static** check: it parses `json_output.txt` and the SQL files on
disk. No database connection, no credentials, no Docker. That makes it
safe to run on every commit.

```
production: 30 tables / 92 policies / 42 triggers / 72 functions / buckets: farm-images
schema_production.sql: 30 tables | init.sql: 29 tables | migrations/: 73 fn / 63 policies / 50 trg
```

### The migration gate

```powershell
python supabase\tools\verify_migration.py supabase\migrations\*.sql
```

A second static gate, one file at a time, covering three properties:

| Check | Rule |
|---|---|
| **structure** | dollar-quote delimiters balanced (both `$$` and `$tag$`); a transaction `BEGIN` is matched by a `COMMIT`/`ROLLBACK`; file ends on a terminator |
| **idempotency** | every `CREATE TABLE/INDEX/SEQUENCE/VIEW` is `IF NOT EXISTS`; every `DROP` is `IF EXISTS`; every `CREATE TRIGGER/POLICY` is preceded by a `DROP ... IF EXISTS` of the same name (PostgreSQL has no `IF NOT EXISTS` for those) |
| **vs reference** | every `REFERENCES` target and every `FROM`/`INTO`/`UPDATE` names a table that exists in `json_output.txt`; an `ADD COLUMN` for a column production already has is flagged as a silent no-op |

`UNIFIED_schema.sql` is **excluded**: it is a from-scratch bootstrap whose
purpose is bare `CREATE TABLE`, so idempotency does not apply to it. So is
`init.sql`. The exclusion is deliberate, not a way to hide a failure.

**What this gate does not cover:** it reads SQL, it does not execute it.
SQL semantics, index usage, lock behaviour and actual RLS evaluation all
require a live PostgreSQL. See the testing-status note in §5.

---

## 6. Validation triggers (W2 / M5)

Every table that carries `flock_id` is guarded by `validate_flock_farm()`
(`BEFORE INSERT OR UPDATE`): a row naming a flock of another farm is
refused; `flock_id IS NULL` passes (farm-level rows are legitimate).

| Table | Trigger | Introduced by |
|---|---|---|
| egg_production | `trg_validate_flock_farm` | `init.sql` §13 |
| mortality | `trg_validate_flock_mortality` | `init.sql` §13 |
| feed_consumption | `trg_validate_flock_feed` | `init.sql` §13 |
| medications | `trg_validate_flock_med` | `init.sql` §13 |
| opening_balances | `trg_validate_flock_ob` | `init.sql` §13 |
| flock_movements | `trg_validate_flock_movements` | `20260927000000` (W0.1) |
| egg_dispatch | `trg_validate_flock_dispatch` | `20260927000000` (W0.1) |
| feed_received | `trg_validate_flock_feed_recv` | `20260927000000` (W0.1) |
| expenses | `trg_validate_flock_expenses` | `20261003000100` (M1) |
| stock_adjustments | `trg_validate_flock_sa` | `20261003000500` (M5) — was missing |

`require_farm_id()` (`BEFORE INSERT OR UPDATE`) refuses `farm_id IS NULL`
with a stable message (`farm_id is required (table %)`) on egg_dispatch,
feed_received, stock_adjustments, expenses and medications. All five
triggers and the function belong to `20261003000500` (M5).

### `revenue.worker_id` is UUID (M7)

`revenue.worker_id` is the **last** `worker_id` column to carry a loose
`text` type; the other eight (`dispatch_requests`, `egg_dispatch`,
`egg_production`, `feed_consumption`, `feed_received`, `flock_movements`,
`medications`, `mortality`) are all `uuid REFERENCES users(id)`. M7 —
`20261003000700` / rollback `20261003000701` — closes it:

- **precheck** refuses the migration while any non-empty non-uuid value is
  on file (`found % invalid worker_id values in revenue`);
- **conversion** `ALTER COLUMN worker_id TYPE uuid USING
  NULLIF(worker_id, '')::uuid` — `''` (what the app writes today) becomes
  `NULL`, valid uuid strings are preserved;
- **FK** `revenue_worker_id_fkey -> users(id) ON DELETE SET NULL` (a revenue
  record must survive the user that logged it — the gate rejects CASCADE for
  `worker_id`);
- **index** `idx_revenue_worker` for the by-worker query pattern;
- the conversion is **conditional on the column still being `text`**, so a
  re-apply is a safe no-op (naively re-checking `worker_id <> ''` against a
  uuid column raises `invalid input syntax for type uuid: ''`).

`p0_revenue_worker_id_test.sql` (suite **4m** in `run_all.py`) verifies
type/FK/index, all 9 `worker_id` columns being uuid, ON DELETE SET NULL,
idempotent re-apply, the rollback, the `'' -> NULL` conversion with preserved
counts, and that revenue's RLS is untouched.

### Financial RLS is manager-only (M8)

The six money tables — `payments`, `expenses`, `revenue`,
`opening_balances`, `inventory_items`, `stock_adjustments` — carry exactly
four policies each, all `TO authenticated`:

| Command | Predicate |
|---|---|
| `SELECT` (`<table>_read`) | `is_system_admin() OR user_manages_farm(farm_id)` |
| `INSERT` (`<table>_insert`) | same, as `WITH CHECK` |
| `UPDATE` (`<table>_update`) | same, as `USING` + `WITH CHECK` |
| `DELETE` (`<table>_delete`) | same, as `USING` |

`user_manages_farm()` requires a `manager` (or `system_admin`) listed in
`user_farms` for the farm, so a worker sees **zero** financial rows and
cannot write one — the M8 `worker_financial_blind` invariant. Cross-farm
reads/writes are also denied because the predicate is farm-scoped per row.

History: `20260926000800` had weakened these tables to
`user_has_farm_access` (true for any farm member, worker included).
`20261002000000_restore_financial_rls.sql` (M8 forward) dropped **every**
policy on the six tables — name-targeted DROPs are unsafe because PostgreSQL
ORs matching policies — and recreated the manager-scoped shape above, then
verifies none of the six tables is left permissive, `authenticated`-only.
Rollback `20261002000001` restores the 00800 weakened shape verbatim.

> **Deliberate exception — `customers` is *not* manager-gated.** The worker
> must read and update the farm's address book (`customers.account_name`,
> phone, `is_global`, custom `last_seen`) while dispatching production, so
> `customers` keeps `user_has_farm_access`. This is a conscious product
> decision (see SECURITY_AUDIT §4), not a SEC-002-style regression: it
> exposes contact-book rows, never financial figures. Re-gating it would
> require a UI/API path that reads the address book as the manager and would
> break dispatch.

`p0_financial_rls_guard_test.sql` (suite **4c**) proves the invariant:
worker cannot read/insert/update/delete money; manager sees and writes only
their farm; sysadmin bypasses; sync still pushes as the manager; worker can
still record production. STEP 10 replays the rollback (asserting the pre-M8
shape returns) and STEP 11 replays the forward (asserting the guard comes
back), all inside `BEGIN/ROLLBACK`.

Every new guard ships with a test: `supabase/tests/
p0_validate_flock_farm_coverage_test.sql` (33 assertions, suite **4h**
in `run_all.py`). Rollback ownership for each trigger is documented in
`docs/SECURITY.md`.

### Schema version marker (M9)

`app_schema_version` (`20261003000900`) is the project's **read-open
exception** — deliberately. A version number is not farm data:

| Column | Type | Notes |
|---|---|---|
| `version` | `integer NOT NULL PRIMARY KEY` | highest value is the live schema |
| `min_client_version` | `integer NOT NULL` | lowest client that may sync |
| `applied_at` | `timestamptz NOT NULL DEFAULT now()` | row landing time |
| `notes` | `text` | human note (first row: `'initial'`) |

- `current_schema_version()` = `SELECT version ... ORDER BY version DESC
  LIMIT 1`, `LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public`.
  Granted `EXECUTE` to `authenticated` **only** — `anon` gets neither it nor
  `SELECT`, so the value is not exposed pre-auth. PostgREST exposes it at
  `/rest/v1/rpc/current_schema_version`.
- RLS `app_schema_version_read FOR SELECT USING (true)` `TO authenticated` —
  read-open so any logged-in user proves their client against the server.
- The table is **metadata**, not a synced table: it is absent from
  `sync_table_registry`, so it never replicates. Clients read the RPC at
  boot, never the table.
- The migration ends with a hard-verification `DO` block (1 row, function
  returns 1) — raises otherwise, per §6 conventions.

Client side (v30): `packages/data/.../local_database.dart` writes
`schema_version` = `_dbVersion` into `local_schema_meta` and exposes
`LocalDatabase.getLocalSchemaVersion()`. Both apps compare it against
`fetchServerSchemaVersion()` at boot and **block** on a mismatch, while any
fetch error is treated as offline (never blocks). The Sync Center (mobile)
shows both versions. Bump procedure, messages and gate semantics:
`docs/SYNC.md`.

`p0_schema_version_test.sql` (suite **4n**) proves: table + single `(1, 1,
'initial')` row exist; the function returns `1` as `test_runner` and as any
`authenticated` identity; the read-open policy; `anon` blocked on both
`SELECT` and `EXECUTE`; the table absent from `sync_table_registry`; the
idempotent re-apply keeps one row; the rollback removes table + function;
and a forward re-apply restores everything.

---

## 8. Report mode (M11) — what analytics read from the schema

M11 is **client-side only** (no DDL). It tightens how analytics derive
period values vs. lifetime values from existing tables. Sourcing map:

| Analytics input | Table / columns | Period mode | Cumulative mode |
|---|---|---|---|
| Egg production | `egg_production` (`total_eggs` via cartons/trays/loose) | rows whose `date` ∈ range | same |
| Legacy eggs (pre-system) | `opening_balances.eggs_produced` | **0** — excluded | full sum, **no** `created_at` filter |
| Mortality | `mortality.count` | rows where `date` ∈ range | same |
| Legacy mortality | `opening_balances.mortality_count` | **0** | full sum, no `created_at` filter |
| Feed | `feed_consumption.quantity_kg` / `feed_received.quantity_kg` | `date` ∈ range | same |
| Legacy feed | `opening_balances.feed_consumed_kg` | **0** | full sum |
| Legacy money | `opening_balances.total_payments` / `total_revenues` | **0** | full sum |

Rule of thumb: **`opening_balances` is *always* a post-system opening-balance
legacy snapshot; in «فترة» it represents nothing inside the chosen window, so
every KPI zeroes it; in «تراكمي» it is history that must not be hidden,
so it is summed in full and never date-filtered.** The `created_at`-based
filter that previously let old balances leak into narrow windows was
removed — the mode switch now owns that decision (see `docs/REPORTS.md`).

The single source of truth for the classification is `ReportMode`, defined
in `packages/core/lib/src/services/phase1_analytics.dart` and carried by
`DateRange.mode` into every calculator and provider. `DateRange.all()`
defaults to `ReportMode.cumulative`; all other presets default to
`ReportMode.period`.

