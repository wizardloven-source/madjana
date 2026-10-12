# PARTNERS — the W6 partnership model (Madjana)

This document explains the partnership/accounting layer that W6 adds on top of
the farm schema. It is the human companion to the migration files; the
machine-checked shape of every table still lives in `json_output.txt` and
`docs/SCHEMA_REFERENCE.md`.

Navigation: `docs/SCHEMA_REFERENCE.md` (contract) · `docs/ACCOUNTING_RULES.md`
(money rules) · `docs/SECURITY.md` (roles) · `docs/SYNC.md` (offline).

---

## 1. The idea

Two of the ten standing principles shape this whole layer:

> **#9 — a partner is an *attribute* of a person, not a role.**
> **#1 — the worker never sees the finances, ever.**

So partnership is modelled in four independent pieces, and a user's *effective*
permission is the combination of all of them:

```
    users.role          base role        (legacy, single role: worker/manager/system_admin)
  + user_roles          dynamic roles    (this doc, M21, per-farm, farm_id NULL = global)
  + partners            the attribute    (this doc, M21: share model + money config)
  + user_permissions    custom overrides (M16, per user × farm × capability)
  + role_permissions    role defaults    (M16, per role × capability)
```

Being a partner does **not** grant financial access by itself. A partner who is
also a worker is still a worker and still sees nothing; a partner who is also a
manager sees only the farms they manage. The share configuration on `partners`
is data the profit engine reads — it is not a permission.

---

## 2. Tables

### 2.1 `partners` (M21)
One row per partner. `user_id` is optional (an investor may have no login) and
is `ON DELETE SET NULL`: removing a login must never delete the partner record.
The **share model is dynamic** — `share_model ∈ {percentage, shares, salary,
mixed}` and a CHECK guarantees the matching columns are filled:

| share_model | required |
|---|---|
| `percentage` | `percentage` (0–100) |
| `shares` | `shares` ≥ 0 |
| `salary` | `salary_amount` + `salary_period` |
| `mixed` | `salary_amount` + `salary_period` **and** (`percentage` or `shares`) |

`currency ∈ {dollar, lira}`, `effective_from`/`effective_to` bound the
engagement, `deleted_at` soft-deletes.

### 2.2 `user_roles` (M21)
The dynamic roles a user holds, per farm. `farm_id NULL` = global. Unique on
`(user_id, role, farm_id)` with **NULLS NOT DISTINCT** (a global role cannot be
inserted twice), plus a partial unique index keeping at most one `is_primary`
row per (user, farm). Writes are admin-only; a user may read their own rows and a
manager may read the farm-scoped rows of the farms they manage.

### 2.3 `profit_distributions` + `profit_distribution_details` (M22)
The ledger that turns a farm's profit for a period into per-partner shares.

* **header** — one per `(farm[, flock], period)`. The arithmetic is enforced by
  CHECKs, so a header that does not add up cannot be stored by anyone:
  * `net_profit = total_revenue − total_expenses`
  * `distributable_profit = net_profit − reserve_amount`
  * `period_end ≥ period_start`, all money/number columns non-negative.
* **details** — one line per partner. `farm_id` is denormalised onto the line and
  a **composite FK `(distribution_id, farm_id) → distributions(id, farm_id)`**
  makes it impossible to attach a line to the wrong farm. Money CHECK:
  `net_amount = profit_share + salary_total − deductions`.

### 2.4 `partner_withdrawals` (M23)
A partner's request to take cash out of their share. Ladder:

```
   pending ──▶ approved ──▶ paid
      │            │
      ├──▶ rejected│
      └──▶ cancelled
                   └──▶ cancelled
```

Guarantees, enforced by triggers so they cannot be dodged from any client:

* `validate_partner_withdrawal()` — the partner must exist, and a withdrawal tied
  to a `distribution_id` must point at a distribution **of the same farm**.
* `guard_withdrawal_status()` — only `pending→{approved,rejected,cancelled}` and
  `approved→{paid,cancelled}` are legal; stamps `reviewed_at` / `paid_at`.
* CHECKs — a `rejected` request must carry a `rejection_reason`; a `paid` request
  must carry a `paid_at`; `amount > 0`.

### 2.5 `partner_audit` + `record_partner_audit(...)` (M23)
An **append-only** governance trail: who added/removed a partner, changed a
share or a permission, requested/approved/rejected/paid a withdrawal, or
created/approved a distribution.

The client has **no INSERT/UPDATE/DELETE policy and no such grant** — the table
is write-protected at the privilege level. The only entry point is

```sql
public.record_partner_audit(
    p_farm_id, p_action, p_changed_by,
    p_partner_id, p_old_values, p_new_values,
    p_notes, p_correlation_id, p_ip_address) RETURNS uuid
```

a `SECURITY DEFINER` function gated on `is_system_admin()`. Ordinary users
read only. (The M24 workflow functions do **not** write the trail: they may be
called by a farm manager, whereas `record_partner_audit` is admin-only, so
routing a manager's approval through it would fail. If auditing of approvals
is wanted, that belongs in a separate admin-side step.)

### 2.6 Partner workflow functions (M24)
Five `SECURITY DEFINER` functions (pinned `search_path`, EXECUTE to
`authenticated` only) read the ledger:

| function | returns | what it does |
|---|---|---|
| `partner_net_profit(p_partner_id, p_period_start, p_period_end, p_flock_id DEFAULT NULL)` | `numeric` | one partner's profit for the period |
| `partner_pending_withdrawal(p_partner_id)` | `numeric` | `SUM(amount)` of `pending` + `approved` withdrawals |
| `partner_summary(p_partner_id)` | table | name / model / share value / YTD profit / pending / paid |
| `approve_withdrawal(p_withdrawal_id, p_approver_id)` | `void` | `pending → approved`; stamps `reviewed_at`/`reviewed_by` |
| `calculate_profit_distribution(p_farm_id, p_period_start, p_period_end, p_flock_id DEFAULT NULL)` | table | **preview** the per-partner split (writes nothing) |

When a `p_flock_id` is given, revenue/expenses are scoped to that flock;
otherwise to the whole farm (or, for `partner_net_profit`, across all farms —
see the adaptation note below). `calculate_*` raises `MIXED_CURRENCY` when the
period's books span two currencies and `INVALID_PERCENTAGES` when the active
percentage partners sum above 100.

**Spec ↔ schema adaptations** (the M24 spec predated the shipped M21/M22):

* `partners` has **no `farm_id`, no `effective_share`, no `salary_model`**. A
  partner is global; the effective share is derived from `share_model`
  (`percentage`→`percentage`, `shares`→`shares`, `salary`→`salary_amount`,
  `mixed`→`COALESCE(percentage, shares, salary_amount)`).
* the period arguments **are** honoured (`date BETWEEN p_period_start AND
  p_period_end`), unlike the raw spec bodies.
* share maths is per model (`percentage`: `net×pct/100`; `shares`:
  `net×shares/Σshares` over active partners with a `shares` value; `salary`:
  `0` + the salary; `mixed`: percentage if set else shares-normalised, + salary).
* `partner_net_profit` without a `p_flock_id` aggregates across **all farms**
  (there is no farm argument to scope by).
* `calculate_profit_distribution` is **read-only** — it does not write
  `profit_distributions`/`details`.

**Authorization** is inside each function (the tables they read are RLS, but
the functions are `SECURITY DEFINER`): `partner_net_profit` and
`partner_summary` allow `is_system_admin()` or the partner's own `user_id`
(plus a manager of the flock's farm when `p_flock_id` is given);
`partner_pending_withdrawal` adds a manager of a farm where the partner has a
withdrawal; `calculate_profit_distribution` allows `is_system_admin()` or
`user_manages_farm(p_farm_id)`; `approve_withdrawal` allows
`is_system_admin()` or `user_manages_farm(farm)`. All raise
`AUTHORIZATION_DENIED` otherwise. This deviates from the spec's "calculate is
admin-only" line, which conflicted with its own "manager may preview" rule.

---

## 3. Money & currency

* Every money column is `NUMERIC(16,8)` (matches `revenue.amount` /
  `expenses.amount`), `exchange_rate NUMERIC(12,4)`, `percentage NUMERIC(9,4)`,
  `shares NUMERIC(18,4)`.
* `currency ∈ {dollar, lira}`; never store mixed currencies in one column
  without an `exchange_rate`.

---

## 4. Scoping / RLS matrix

**Canonical as of M25** (§12 of `docs/SECURITY.md`). `S` = SELECT, `I` = INSERT,
`U` = UPDATE, `D` = DELETE. `admin` = `is_system_admin()`; `manager` =
`user_manages_farm(farm_id)`, except on `partners` where it is
`partner_in_manager_farm(id)` (that table has no `farm_id`); `self` = the
caller's own partner/user row.

| table | admin | manager (own farm) | partner (self) | worker | anon |
|---|---|---|---|---|---|
| `partners` | S I U D | S + I U D (farm-scoped) | S (own row) | — | — |
| `user_roles` | S I U D | S + I U D (farm rows) | S (own rows) | S (own rows) | — |
| `profit_distributions` | S I U D | S + I U D | S (reachable) | — | — |
| `profit_distribution_details` | S I U D | S + I U D | S (own lines) | — | — |
| `partner_withdrawals` | S I U D | S U (own farm) | S + I (`pending` only) | — | — |
| `partner_audit` | S | S (own farm) | S (own rows) | — | — |

`partner_audit` is **append-only**: it has no write policy and `authenticated`
holds only `SELECT` (rows come from `record_partner_audit(...)` only). The
`*_manager_write` policies are `FOR ALL` (Postgres has no command-scoped
INSERT-only policy), so "manager" on `partners` / `user_roles` /
`profit_distributions` / `profit_distribution_details` means full CRUD within
their farm.

FK delete rules: `farm_id` / `flock_id` / `partner_id` / `requested_by` →
`RESTRICT`; `user_id` / `created_by` / `approved_by` / `reviewed_by` →
`SET NULL`. **No CASCADE anywhere.**

---

## 5. Sync

* `partner_withdrawals` is a normal synced record: it carries
  `updated_at` / `deleted_at`, the `populate_sync_changes()` trigger and the
  `sync_tombstone_after_delete()` tombstone trigger — the same pattern as
  `change_requests` (M14).
* `partner_audit` is a governance ledger like `farm_id_audit` (M18): it is **not
  synced** and has **no trigger of its own**; M23 only provides the writer
  function.

---

## 6. Migrations, rollback, tests

| step | forward | rollback |
|---|---|---|
| M21 | `20261003002000_m21_partners_user_roles.sql` | `20261003002001` |
| M22 | `20261003002100_m22_profit_distributions.sql` | `20261003002101` |
| M23 | `20261003002200_m23_partner_withdrawals_partner_audit.sql` | `20261003002201` |
| M24 | `20261003002300_m24_partner_functions.sql` | `20261003002301` |
| M25 | `20261003002400_m25_partner_rls.sql` | `20261003002401` |

Every forward file is idempotent, ends with a post-`COMMIT` verification DO
block, and has a scope-guarded rollback (M24's refuses while any processed
withdrawal exists; M25's refuses if any of the six partner tables is missing).
The regression suites `p0_partner_withdrawals_test.sql` (4x),
`p0_partner_audit_test.sql` (4y), `p0_partner_functions_test.sql` (4aa) and
`p0_partner_rls_test.sql` (4ab, **49 assertions**, 24 policies) run through
`supabase/tests/run_all.py`.

Apply to production by pasting the forward files, in order, into the Supabase
SQL Editor (the DB is not reachable from the dev box). Re-running is safe.

---

## 7. Roadmap

* **M24 — done.** The workflow functions (`partner_net_profit`,
  `calculate_profit_distribution`, `approve_withdrawal`,
  `partner_pending_withdrawal`, `partner_summary`). See §2.6.
* **M25 — done.** Canonical RLS across the six partnership tables (24
  policies) + the `partner_in_manager_farm(uuid)` bridge helper. See §4 and
  `docs/SECURITY.md` §12.
* **M26–M28** — reporting, reconciliation and the client surface.
