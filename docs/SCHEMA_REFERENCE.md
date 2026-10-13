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
| 2026-10-12 | W6-M21: `partners` (partner = an **attribute** of a person, not a role; dynamic share model percentage/shares/salary/mixed) + `user_roles` (dynamic per-farm roles, `farm_id NULL` = global, `UNIQUE NULLS NOT DISTINCT`). Admin-only writes; partner may read own row; user may read own roles; manager may read farm-scoped roles. Forward `20261003002000`, rollback `20261003002001`. |
| 2026-10-12 | W6-M22: `profit_distributions` (one period per farm[/flock], header arithmetic enforced: `net_profit = total_revenue − total_expenses`, `distributable_profit = net_profit − reserve_amount`) + `profit_distribution_details` (per-partner lines; composite FK `(distribution_id, farm_id)` prevents attaching a line to the wrong farm). Forward `20261003002100`, rollback `20261003002101`, live checks green. |
| 2026-10-12 | W6-M23: `partner_withdrawals` (cash-out ladder `pending→approved→paid`, or `rejected`/`cancelled`; `validate_partner_withdrawal()` + `guard_withdrawal_status()` BEFORE triggers; state↔field CHECKs; 5 RLS policies — admin all, partner self-read/self-insert pending-only, manager read/update) + `partner_audit` (append-only trail; **no** INSERT/UPDATE/DELETE policy or grant; the only client entry point is `record_partner_audit(...)` SECURITY DEFINER, admin-gated). Forward `20261003002200`, rollback `20261003002201`, suites **4x**/**4y**. Full design in `docs/PARTNERS.md`. |
| 2026-10-12 | M1b: `revenue.flock_id` uuid FK → `flocks(id)` ON DELETE RESTRICT, nullable (SET = direct revenue, NULL = farm-level — mirrors `expenses.flock_id` M1). Indexes `idx_revenue_farm_flock`, `idx_revenue_flock_direct`; guard `trg_validate_flock_revenue`. Forward `20261003000150`, rollback `20261003000151`, suite **4z**. RLS untouched (revenue is manager-only, M8). |
| 2026-10-12 | W6-M24: partner workflow engine — `partner_net_profit(uuid,date,date,uuid)`, `partner_pending_withdrawal(uuid)`, `partner_summary(uuid)`, `approve_withdrawal(uuid,uuid)`, `calculate_profit_distribution(uuid,date,date,uuid)`. All **SECURITY DEFINER** with pinned `search_path`; EXECUTE to `authenticated` only (never anon/PUBLIC). `calculate_profit_distribution` is a **read-only preview** (`RETURNS TABLE`, writes nothing). Forward `20261003002300`, rollback `20261003002301`, suite **4aa**. Spec↔schema adaptations and share math live in `docs/PARTNERS.md` §2.6. |
| 2026-10-12 | W6-M25: **canonical RLS** for the six partnership tables — 24 policies (4/4/4/4/5/3): `partners`, `user_roles`, `profit_distributions`, `profit_distribution_details`, `partner_withdrawals`, `partner_audit`. Replaces the M21–M23 policy set. New helper `partner_in_manager_farm(uuid)` (SECURITY DEFINER, STABLE, pinned `search_path`, `authenticated`-only) bridges `partners` (no `farm_id`) to farm managers without tripping policy recursion. `partner_audit` stays append-only (no write policy/grant; admin direct INSERT refused). Forward `20261003002400`, rollback `20261003002401`, suite **4ab**. Design in `docs/SECURITY.md` §12. |
| 2026-10-13 | W6-M26: consolidated W6 rollback `20261003002450_rollback_w6_all.sql` (one-transaction teardown in strict dependency order) + the apply→rollback→re-apply cycle proof `supabase/tests/test_w6_rollback_cycles.py` (step **3c**). No schema change — see `docs/DEPLOYMENT.md` §8. |
| 2026-10-13 | W6-M27: comprehensive partner test suites — `p0_partner_e2e_test.sql` (**4ac**, 30 assertions, full lifecycle), `p0_partner_reports_test.sql` (**4ad**, 36 assertions, four share models + error rails), `p0_partner_isolation_test.sql` (**4ae**, 47 assertions, cross-farm/cross-partner isolation + composite-FK rejection). Tests only, no schema change. |
| 2026-10-13 | W6-M28: final W6 documentation — per-object schema reference (§9 below), worked examples/workflows in `docs/PARTNERS.md`, partner accounting rules in `docs/ACCOUNTING_RULES.md` §12, the W6 deployment runbook (`docs/DEPLOYMENT.md` §9) and the consolidated change log. No schema change. |

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
| revenue | `trg_validate_flock_revenue` | `20261003000150` (M1b) |
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

---

## 9. Partnership schema (W6 — M1b, M21–M25)

W6 adds one column to an existing table and six new tables, plus nine
functions. The human-facing design (why the model is shaped this way, how
roles combine, and worked workflows) lives in `docs/PARTNERS.md`; the RLS
matrix and its rationale live in `docs/SECURITY.md` §12. **This section is
only the shape** — the objects `json_output.txt` should contain once W6 is
applied. Every object is created by a forward file and removed by its
matching `…01_rollback_*.sql`, or by the consolidated
`20261003002450_rollback_w6_all.sql` (`docs/DEPLOYMENT.md` §8).

### 9.1 `revenue.flock_id` (M1b)

| Column | Type | Notes |
|---|---|---|
| `flock_id` | `uuid` NULL | FK → `flocks(id)` ON DELETE RESTRICT. **SET** = direct revenue of that flock; **NULL** = farm-level revenue. Mirrors `expenses.flock_id`. Guarded by `trg_validate_flock_revenue`; indexes `idx_revenue_farm_flock`, `idx_revenue_flock_direct`. RLS untouched (revenue is manager-only, M8). |

Forward `20261003000150`, rollback `20261003000151`, suite **4z**.

### 9.2 `partners` (M21)

One row per partner. A partner is an **attribute of a person, not a role**,
and `user_id` is optional (a pure investor may have no login) with
`ON DELETE SET NULL`.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | `gen_random_uuid()` |
| `user_id` | `uuid` NULL | FK → `users(id)` ON DELETE SET NULL; `UNIQUE` (`partners_user_unique`) |
| `name` | `text` NOT NULL | non-blank (`char_length(btrim(name)) > 0`) |
| `phone` | `text` | |
| `national_id` | `text` | |
| `status` | `text` NOT NULL default `'active'` | `active` \| `inactive` \| `suspended` |
| `partner_role` | `text` NOT NULL default `'investor'` | `investor` \| `worker` \| `manager` \| `silent` \| `mixed` |
| `share_model` | `text` NOT NULL default `'percentage'` | `percentage` \| `shares` \| `salary` \| `mixed` |
| `percentage` | `numeric(9,4)` NULL | 0–100 |
| `shares` | `numeric(18,4)` NULL | ≥ 0 |
| `salary_amount` | `numeric(16,8)` NULL | ≥ 0 |
| `salary_period` | `text` NULL | `monthly` \| `weekly` \| `daily` \| `per_cycle` |
| `currency` | `text` NOT NULL default `'dollar'` | `dollar` \| `lira` |
| `effective_from` | `date` NOT NULL default `CURRENT_DATE` | |
| `effective_to` | `date` NULL | ≥ `effective_from` |
| `meta` | `jsonb` NOT NULL default `'{}'` | |
| `created_by` | `uuid` NULL | FK → `users(id)` ON DELETE SET NULL |
| `created_at` / `updated_at` | `timestamptz` NOT NULL default `now()` | |
| `deleted_at` | `timestamptz` NULL | soft delete |

Constraints: `partners_share_model_fields` (the share columns required by
`share_model`), `partners_effective_range`. Indexes `idx_partners_user`,
`idx_partners_status`, `idx_partners_role` (both partial on
`deleted_at IS NULL`). Trigger `trg_partners_updated_at`.

### 9.3 `user_roles` (M21)

The dynamic roles a user holds, **per farm** (`farm_id NULL` = global).
Separate from `users.role` (legacy base role) and `role_permissions` (M16
defaults).

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | |
| `user_id` | `uuid` NOT NULL | FK → `users(id)` ON DELETE RESTRICT |
| `farm_id` | `uuid` NULL | FK → `farms(id)` ON DELETE RESTRICT; NULL = global |
| `role` | `text` NOT NULL | non-blank |
| `is_primary` | `boolean` NOT NULL default `false` | at most one primary per (user, farm) |
| `effective_from` / `effective_to` | `date` | `effective_to` ≥ `effective_from` |
| `granted_by` | `uuid` NULL | FK → `users(id)` ON DELETE SET NULL |
| `created_at` / `updated_at` | `timestamptz` NOT NULL default `now()` | |

Constraints: `user_roles_unique` = `UNIQUE NULLS NOT DISTINCT (user_id,
role, farm_id)`; `user_roles_effective_range`; partial unique index
`ux_user_roles_primary` on `(user_id, COALESCE(farm_id, 0-uuid)) WHERE
is_primary`. Indexes `idx_user_roles_user`, `idx_user_roles_farm`,
`idx_user_roles_role`. Trigger `trg_user_roles_updated_at`.

### 9.4 `profit_distributions` (M22)

The header: one row per `(farm[, flock], period)`. Every money column is
`numeric(16,8)` (matching `revenue.amount` / `expenses.amount`).

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | |
| `farm_id` | `uuid` NOT NULL | FK → `farms(id)` ON DELETE RESTRICT |
| `flock_id` | `uuid` NULL | FK → `flocks(id)` ON DELETE RESTRICT; NULL = whole farm |
| `period_start` / `period_end` | `date` NOT NULL | `period_end` ≥ `period_start` |
| `label` | `text` | |
| `status` | `text` NOT NULL default `'draft'` | `draft` \| `calculated` \| `approved` \| `distributed` \| `cancelled` |
| `total_revenue` / `total_expenses` | `numeric(16,8)` NOT NULL default `0` | ≥ 0 |
| `net_profit` | `numeric(16,8)` NOT NULL default `0` | `= total_revenue − total_expenses` |
| `reserve_amount` | `numeric(16,8)` NOT NULL default `0` | ≥ 0 |
| `distributable_profit` | `numeric(16,8)` NOT NULL default `0` | `= net_profit − reserve_amount` |
| `currency` | `text` NOT NULL default `'dollar'` | `dollar` \| `lira` |
| `exchange_rate` | `numeric(12,4)` | |
| `notes` | `text` | |
| `meta` | `jsonb` NOT NULL default `'{}'` | |
| `calculated_at` / `approved_at` | `timestamptz` | |
| `approved_by` / `created_by` | `uuid` NULL | FK → `users(id)` ON DELETE SET NULL |
| `created_at` / `updated_at` | `timestamptz` NOT NULL default `now()` | |

Constraints: `profit_distributions_period` (range), `profit_distributions_math`
(`net_profit = total_revenue − total_expenses`),
`profit_distributions_distributable` (arithmetic),
`profit_distributions_period_unique` = `UNIQUE NULLS NOT DISTINCT
(farm_id, flock_id, period_start, period_end)`, and `profit_distributions_id_farm_unique`
= `UNIQUE (id, farm_id)` (the target of the details composite FK). Indexes
`idx_profit_distributions_farm`, `idx_profit_distributions_flock`,
`idx_profit_distributions_status`. Trigger `trg_profit_distributions_updated_at`.

### 9.5 `profit_distribution_details` (M22)

The lines: one per partner per header. `farm_id` is denormalised onto the
line so a **composite FK** `(distribution_id, farm_id) →
profit_distributions(id, farm_id)` makes attaching a line to the wrong farm
impossible.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | |
| `distribution_id` | `uuid` NOT NULL | FK → `profit_distributions(id)` ON DELETE RESTRICT |
| `farm_id` | `uuid` NOT NULL | FK → `farms(id)` ON DELETE RESTRICT |
| `partner_id` | `uuid` NOT NULL | FK → `partners(id)` ON DELETE RESTRICT |
| `share_model` | `text` NOT NULL | `percentage` \| `shares` \| `salary` \| `mixed` |
| `percentage` / `shares` / `salary_amount` / `salary_period` | as `partners` | model inputs copied onto the line |
| `profit_share` / `salary_total` / `deductions` | `numeric(16,8)` NOT NULL default `0` | ≥ 0 |
| `net_amount` | `numeric(16,8)` NOT NULL default `0` | `= profit_share + salary_total − deductions` |
| `currency` | `text` NOT NULL default `'dollar'` | `dollar` \| `lira` |
| `status` | `text` NOT NULL default `'pending'` | `pending` \| `approved` \| `withdrawn` \| `cancelled` |
| `note` / `meta` / `created_at` / `updated_at` | | |

Constraints: `profit_distribution_details_math`,
`profit_distribution_details_unique` = `UNIQUE (distribution_id, partner_id)`,
`profit_distribution_details_dist_farm_fkey` (the composite FK). Indexes
`idx_pdd_distribution`, `idx_pdd_partner`, `idx_pdd_farm`, `idx_pdd_status`.
Trigger `trg_pdd_updated_at`.

### 9.6 `partner_withdrawals` (M23)

A partner's cash-out request; the ladder is `pending → approved → paid`, or
`rejected` / `cancelled` (`docs/PARTNERS.md` §2.4).

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | |
| `partner_id` | `uuid` NOT NULL | FK → `partners(id)` ON DELETE RESTRICT |
| `farm_id` | `uuid` NOT NULL | FK → `farms(id)` ON DELETE RESTRICT |
| `distribution_id` | `uuid` NULL | FK → `profit_distributions(id)` ON DELETE SET NULL |
| `amount` | `numeric(16,8)` NOT NULL | > 0 |
| `currency` | `text` NOT NULL default `'dollar'` | `dollar` \| `lira` |
| `status` | `text` NOT NULL default `'pending'` | `pending` \| `approved` \| `rejected` \| `paid` \| `cancelled` |
| `requested_at` | `timestamptz` NOT NULL default `now()` | |
| `requested_by` | `uuid` NOT NULL | FK → `users(id)` ON DELETE RESTRICT |
| `reason` / `notes` / `payment_method` | `text` | |
| `reviewed_at` / `reviewed_by` | `timestamptz` / `uuid` NULL | `reviewed_by` FK → `users(id)` ON DELETE SET NULL |
| `rejection_reason` | `text` | required when `status = 'rejected'` |
| `paid_at` | `timestamptz` | required when `status = 'paid'` |
| `version` | `bigint` NOT NULL default `0` | sync OCC |
| `created_at` / `updated_at` | `timestamptz` NOT NULL default `now()` | |
| `deleted_at` | `timestamptz` NULL | soft delete (synced) |

Constraints: `partner_withdrawals_rejected_reason`,
`partner_withdrawals_paid_at`. Indexes on partner/farm/status/distribution
and `created_at DESC`. Five triggers: `trg_partner_withdrawals_updated_at`,
`_validate` (`validate_partner_withdrawal`), `_guard`
(`guard_withdrawal_status`), `_sync` (`populate_sync_changes`), `_tombstone`
(`sync_tombstone_after_delete`).

### 9.7 `partner_audit` (M23)

An **append-only** governance ledger. No client write policy exists and
`authenticated` holds only `SELECT`; rows enter solely through
`record_partner_audit(...)`. It has **no triggers** and is not synced.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | |
| `farm_id` | `uuid` NOT NULL | FK → `farms(id)` ON DELETE RESTRICT |
| `partner_id` | `uuid` NULL | FK → `partners(id)` ON DELETE SET NULL |
| `action` | `text` NOT NULL | `added` \| `removed` \| `share_changed` \| `permissions_changed` \| `withdrawal_requested` \| `withdrawal_approved` \| `withdrawal_rejected` \| `withdrawal_paid` \| `distribution_created` \| `distribution_approved` |
| `old_values` / `new_values` | `jsonb` | |
| `changed_by` | `uuid` NOT NULL | FK → `users(id)` ON DELETE RESTRICT |
| `changed_at` | `timestamptz` NOT NULL default `now()` | |
| `notes` / `correlation_id` / `ip_address` | `text` | |

Indexes `idx_partner_audit_farm`, `_partner`, `_action`, `_changed_at`.

### 9.8 Functions (9)

All are `SECURITY DEFINER` with a pinned `search_path`; `EXECUTE` is granted
to `authenticated` only (never `anon`/`PUBLIC`). `public.` prefix omitted.

| Function | Signature | Kind / notes |
|---|---|---|
| `validate_partner_withdrawal` | `() → trigger` | partner must exist; a tied `distribution_id` must be the same farm (`WITHDRAWAL_DISTRIBUTION_MISMATCH`) |
| `guard_withdrawal_status` | `() → trigger` | enforces the status ladder; stamps `reviewed_at` / `paid_at` |
| `record_partner_audit` | `(uuid, text, uuid, uuid, jsonb, jsonb, text, text, text) → uuid` | the only writer of `partner_audit`; gated on `is_system_admin()` |
| `partner_in_manager_farm` | `(uuid) → boolean` | SQL, STABLE; policy-recursion breaker (`docs/SECURITY.md` §12) |
| `partner_net_profit` | `(uuid, date, date, uuid DEFAULT NULL) → numeric` | one partner's profit for a period |
| `partner_pending_withdrawal` | `(uuid) → numeric` | sum of `pending` + `approved` |
| `partner_summary` | `(uuid) → TABLE(name text, share_model text, share_value numeric, net_profit numeric, pending numeric, paid numeric)` | YTD snapshot |
| `approve_withdrawal` | `(uuid, uuid) → void` | `pending → approved` |
| `calculate_profit_distribution` | `(uuid, date, date, uuid DEFAULT NULL) → TABLE(partner_id uuid, share_type text, share_value numeric, amount numeric)` | read-only preview; raises `MIXED_CURRENCY` / `INVALID_PERCENTAGES` |

The share maths each function implements, the authorization gates and the
spec↔schema adaptations are in `docs/PARTNERS.md` §2.6; the accounting rules
they enforce are in `docs/ACCOUNTING_RULES.md` §12.

### 9.9 RLS and grants

Six tables carry the canonical 24-policy matrix (4 / 4 / 4 / 4 / 5 / 3) from
M25. The full matrix, predicates, `partner_audit` append-only proof and the
`partner_in_manager_farm` rationale live in `docs/SECURITY.md` §12 — not
repeated here. `anon` and `PUBLIC` have no access to any W6 table or
function.

