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

Two independent classifications ride along, both purely descriptive — neither
grants a permission:

* `status ∈ {active, inactive, suspended}` — whether the engagement is live.
* `partner_role ∈ {investor, worker, manager, silent, mixed}` — the *flavour*
  of the partner. A `silent` partner is money-only (no operational say), a
  `mixed` partner both invests and works; a person may be `worker` as a
  partner and still be a plain worker by `users.role`.

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
`p0_partner_audit_test.sql` (4y), `p0_partner_functions_test.sql` (4aa,
56 assertions), `p0_partner_rls_test.sql` (4ab, **49 assertions**, 24
policies), `p0_partner_e2e_test.sql` (4ac, 30 assertions — the full
partner → distribution → withdrawal → paid → audit lifecycle),
`p0_partner_reports_test.sql` (4ad, 36 assertions — the four share models,
period/flock boundaries, empty period, 100% sum and the error rails) and
`p0_partner_isolation_test.sql` (4ae, 47 assertions — cross-farm /
cross-partner reads, writes and the composite-FK rejection) run through
`supabase/tests/run_all.py`. Rollback idempotency (apply → rollback →
re-apply, per-milestone and consolidated) is proven by
`test_w6_rollback_cycles.py` (step **3c**).

Apply to production by pasting the forward files, in order, into the Supabase
SQL Editor (the DB is not reachable from the dev box). Re-running is safe.

---

## 7. Workflows (worked examples)

Every example below assumes the caller's session is set
(`SET LOCAL request.jwt.claims = '{"sub":"<user-uuid>","role":"authenticated"}'`
or `tests.set_user(...)` in the suites). Bits of a real UUID are shortened.

### 7.1 Create a partner (admin only)

```sql
INSERT INTO public.partners (name, share_model, percentage, currency)
VALUES ('مزارع أحمد', 'percentage', 25, 'dollar')
RETURNING id, status, partner_role;
-- → one row; status='active', partner_role='investor', user_id = NULL (no login yet)
```

RLS `partners_admin_all` gates this on `is_system_admin()`. To give the
partner a login later, `UPDATE ... SET user_id = '<uuid>'` (a login is not
required — a pure investor may never have one).

### 7.2 The four share models

| `share_model` | Columns that must be filled | Effective value | Profit split |
|---|---|---|---|
| `percentage` | `percentage` (0–100) | 25 | `distributable_profit × 25 / 100` |
| `shares` | `shares` ≥ 0 | 300 | `distributable_profit × 300 / Σshares` (active shares partners) |
| `salary` | `salary_amount` + `salary_period` | 500 / `monthly` | **0** profit share + the salary |
| `mixed` | `salary_amount` + `salary_period` **and** (`percentage` or `shares`) | 500 + 10% | salary **plus** the percentage (or shares) split |

A CHECK (`partners_share_model_fields`) refuses a row whose `share_model`
disagrees with the columns it filled, so a `salary` partner who also carries a
`percentage` cannot exist by accident.

### 7.3 Calculate a distribution (read-only preview)

```sql
SELECT * FROM public.calculate_profit_distribution(
    '00000000-0000-0000-0000-000000000001',  -- farm
    '2026-10-01', '2026-10-31',              -- period
    NULL);                                   -- NULL flock = whole farm
-- → one row per active partner: (partner_id, share_type, share_value, amount)
```

`share_type` is the model that priced the line; `amount` is that partner's
share of the distributable profit. The function writes **nothing**. It raises
`MIXED_CURRENCY` if the period's books span two currencies and
`INVALID_PERCENTAGES` if the active percentage partners sum above 100.
Authorization: `is_system_admin()` or a manager of `p_farm_id`, else
`AUTHORIZATION_DENIED`.

### 7.4 Store a distribution (manager / admin)

```sql
INSERT INTO public.profit_distributions
    (farm_id, period_start, period_end,
     total_revenue, total_expenses, reserve_amount, net_profit, distributable_profit)
VALUES ('…farm…', '2026-10-01', '2026-10-31',
        1800, 500, 300, 1300, 1000)
RETURNING id;
-- net_profit = 1800 − 500 = 1300; distributable_profit = 1300 − 300 = 1000
```

The header CHECKs enforce both equations, so a header that does not add up is
rejected by the database, not by the caller. `INSERT` the per-partner
`profit_distribution_details` rows with `farm_id` copied from the header — the
composite FK `(distribution_id, farm_id)` refuses any other farm.

### 7.5 Request a withdrawal (partner, self, `pending` only)

```sql
INSERT INTO public.partner_withdrawals (partner_id, farm_id, amount, requested_by)
VALUES ('…partner…', '…farm…', 100, auth.uid());
-- → status defaults to 'pending'
```

RLS `withdrawals_partner_insert` allows a partner to insert only **their own**
row and only as `status = 'pending'` — a partner cannot self-approve or
self-pay. A withdrawal tied to a `distribution_id` must name a distribution of
the same farm (`validate_partner_withdrawal`), else
`WITHDRAWAL_DISTRIBUTION_MISMATCH`.

### 7.6 Approve (manager / admin)

```sql
SELECT public.approve_withdrawal('…withdrawal…', '…approver…');
-- → status 'pending' → 'approved'; reviewed_by/reviewed_at stamped
```

The function refuses a non-`pending` row (`INVALID_STATUS_TRANSITION`) and
denies anyone but a system admin or a manager of the withdrawal's farm.

### 7.7 Pay

```sql
UPDATE public.partner_withdrawals
   SET status = 'paid'
 WHERE id = '…withdrawal…';
-- guard_withdrawal_status stamps paid_at; the CHECK requires it when status='paid'
```

Only `approved → paid` (or `approved → cancelled`) is legal; every other
transition raises `INVALID_STATUS_TRANSITION`.

### 7.8 Read the summary

```sql
SELECT * FROM public.partner_summary('…partner…');
-- name | share_model | share_value | net_profit (YTD) | pending | paid
```

`net_profit` is **year-to-date** with no flock filter (§2.6); `pending` sums
`pending` + `approved` withdrawals; `paid` sums the paid ones. A partner may
read their own summary; so may a system admin.

### 7.9 The audit trail

The trail is written only by `record_partner_audit(...)` (admin-gated); the
client reads it through `partner_audit`:

```sql
SELECT action, changed_by, changed_at, notes
  FROM public.partner_audit
 WHERE partner_id = '…partner…'
 ORDER BY changed_at DESC;
```

---

## 8. Roadmap

* **M24 — done.** The workflow functions (`partner_net_profit`,
  `calculate_profit_distribution`, `approve_withdrawal`,
  `partner_pending_withdrawal`, `partner_summary`). See §2.6.
* **M25 — done.** Canonical RLS across the six partnership tables (24
  policies) + the `partner_in_manager_farm(uuid)` bridge helper. See §4 and
  `docs/SECURITY.md` §12.
* **M26 — done.** Consolidated W6 rollback (`20261003002450_rollback_w6_all.sql`)
  and the apply → rollback → re-apply cycle proof. See `docs/DEPLOYMENT.md` §8.
* **M27 — done.** End-to-end, reporting and isolation suites (4ac/4ad/4ae).
* **M28 — done.** Final W6 documentation: per-object reference
  (`docs/SCHEMA_REFERENCE.md` §9), these workflows, the accounting rules
  (`docs/ACCOUNTING_RULES.md` §12) and the deploy runbook
  (`docs/DEPLOYMENT.md` §9).
