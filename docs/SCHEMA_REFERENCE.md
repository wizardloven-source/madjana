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
