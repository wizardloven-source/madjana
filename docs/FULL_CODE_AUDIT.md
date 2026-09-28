# YASeen ERP — Full Code Audit

**Date:** 2026-09-16 · **Scope:** READ-ONLY (no files modified, no migrations run, no commits)
**Commit:** `67b7bf40e51ffe8df962bb0feb0774c1bfe9bc2f`
**Stance:** documentation ignored as evidence; every claim traced to code/DB/tests.

---

## 0. THE HEADLINE FINDING

**The premise of the audit brief does not match the repository.**

The brief asks me to audit an ERP accounting engine with Chart of Accounts,
JournalEntry, JournalLine, Ledger, Trial Balance, Fiscal Period, Posting,
Reversal, FIFO cost layers, and FX revaluation.

**None of these exist. Not partially. Not at all.**

Searched across all 189 tracked Dart files and all SQL:

```
journal_entry | journalEntry | journal_line | double_entry |
chart_of_accounts | trial_balance | general_ledger  → 0 results
COGS | cogs | cost_of_goods                           → 0 results
fiscal | period_lock | closed_period                  → 0 results
depreciation | fixed_asset | FixedAsset               → 0 results
```

The complete table list in `supabase/migrations/UNIFIED_schema.sql` is 26 tables:
`farms, users, user_farms, flocks, customers, egg_production, mortality,
feed_consumption, feed_received, egg_dispatch, payments, medications,
medicines_catalog, expenses, revenue, opening_balances, inventory_items,
inventory_transactions, stock_adjustments, audit_log, app_settings,
app_notifications, dispatch_requests, sync_changes, sync_checkpoint,
sync_conflicts, idempotency_log, login_throttle`.


---

## 2. Architecture

### Real structure

```
madjana/
├── packages/core/     Domain: models, enums, repository INTERFACES,
│                     use cases, pure analytics. No I/O.
├── packages/data/     Adapters: local DAOs (sqflite) + remote datasources
│                     (Supabase) + repository IMPLEMENTATIONS
├── apps/desktop/      Flutter Desktop presentation (Riverpod)
├── apps/mobile/       Flutter Mobile presentation (Riverpod)
└── supabase/          PostgreSQL schema + migrations + edge functions
```

Dependency direction is **correct**: `presentation → core(interface) ←
data(implementation)`. `packages/core` has zero imports of `packages/data` or
`supabase`. Verified.

| Layer | Location | Responsibility | Business logic? |
|---|---|---|---|
| Presentation | `apps/*/lib/features/*/presentation/` | Widgets, dialogs, Riverpod | **Yes — too much** (P1) |
| Application | `packages/core/lib/src/usecases/` | 6 use cases | Yes (correctly) |
| Domain | `packages/core/lib/src/models/`, `services/` | Entities, enums, analytics | Yes (correctly) |
| Ports | `packages/core/lib/src/repositories/` | Abstract interfaces | No |
| Adapters | `packages/data/lib/src/datasources/` | DAOs + datasources | Partially |
| Infrastructure | `supabase/migrations/*.sql` | Schema, RLS, triggers, RPC | Yes (correctly) |

### Dependency Map — violations found
- **UI → Repository is pervasive.** Every presentation file calls
  `ref.read(paymentRepositoryProvider)` directly, bypassing use cases. Only 6
  use cases exist for ~15 feature areas.
- **No SQL in UI** — correct, verified by search.
- **No circular imports** — none found.

### Business Module Map

| Module | Implemented | Maturity |
|---|---|---|
| Flocks | YES | Solid — lifecycle, `current_count` via trigger |
| Egg Production | YES | Solid — `calc_total_eggs`, withdrawal-period block |
| Mortality | YES | Solid — trigger decrements `flocks.current_count` |
| Feed In/Consumption | YES | Solid — unit conversion DB-enforced |
| Egg Dispatch | YES | Solid — carton/tray math trigger |
| Customers / Receivables | PARTIAL | **Defective** (§8) |
| Payments | PARTIAL | No atomicity; weak overpayment guard |
| Inventory | PARTIAL | Quantity-only; **no valuation, no cost** |
| Expenses | PARTIAL | Free-text, no AP, no supplier link |
| Revenue | PARTIAL | Manual entry, no source-document link |
| Analytics | YES | Strong pure-function layer, correctly caveated |
| Sync | YES | Strong — most mature subsystem |
| Security | PARTIAL | Strong RLS; audit trail absent |

---

## 3. Accounting Engine

**Status: DOES NOT EXIST.**

No double-entry, no chart of accounts, no journal, no posting, no trial balance,
no fiscal period.

What exists is a **cash-basis single-entry approximation**:
- Revenue = `MAX(total_due)` per dispatch, read from `payments`
  (`phase1_analytics.dart:448`, `FinancialKpi.calculate`).
- Expenses = free-text `expenses` table.
- Margin = `collected - expenses`, named `estimatedMargin`; the code itself
  calls it an estimate.

### Double-entry safety
**Not applicable.** The invariant "Debit == Credit" has no representation in
the schema — it cannot be violated, and equally cannot be guaranteed.

### Where the money lives
The entire financial position of a customer is one mutable column:

```sql
-- UNIFIED_schema.sql : customers
total_debt NUMERIC(...)
```

Maintained by a single trigger. That trigger contains the worst bug (§8).

Not one is an accounting table.

**What YASeen ERP actually is:** an **offline-first poultry farm operations
management system** (flocks, egg production, mortality, feed, egg dispatch,
customer receivables) built with Flutter Desktop + Flutter Mobile + Supabase.

---

## 4. Journal Entry Lifecycle

**Status: DOES NOT EXIST.** No journals → no create/draft/validate/approve/
post/lock/reverse lifecycle, no segregation of duties.

The closest analogue — the payment path — is where I looked hardest:

| Concern | Finding |
|---|---|
| Who can create a payment? | `mgr_all` on `payments`: manager or system_admin only. Worker **cannot**. **Correct.** |
| Who can edit/delete? | Same `mgr_all` FOR ALL. Manager can delete at will — no immutability. |
| Re-posting | N/A. But **duplicate payment rows are possible** (§19). |
| Idempotency | None at payment level. `idempotency_log` exists, unused by `payments`. |
| Optimistic locking | `version BIGINT` used by the *sync* engine, not for business integrity. |
| Race conditions | Present (§19). |

---

## 5. Sales

### Sales flow map

| Stage | File | Function/Class | DB operation | Transaction |
|---|---|---|---|---|
| Create dispatch | `packages/core/lib/src/usecases/save_dispatch_usecase.dart` | `SaveDispatchUseCase.call` | — | **NONE** |
| Validate date/qty | same | `call()` L27-33 | in-memory | n/a |
| Withdrawal check | same | `_checkWithdrawalPeriod` | `medications` read | n/a |
| Persist dispatch | `packages/data/.../dispatch_dao.dart` | `DispatchDao.insert` | `db.insert` + `enqueueChange` | **NONE** |
| Open zero invoice | `save_dispatch_usecase.dart` | `_openInvoice` | `payments.insert` | **NONE** |
| Price invoice | `apps/desktop/.../dispatch_screen.dart` | `_recordPayment` | `updateInvoiceForDispatch` | **NONE** |
| Record collection | `payment_repository_impl.dart` | `PaymentRepositoryImpl.save` | `payments.insert` + `updateSyncStatus` + `dispatch.payment_status` | **NONE** |
| Recalc debt | Postgres trigger | `recalc_customer_debt()` | `UPDATE customers` | in-txn |

### Is the flow atomic? **No** (§18).

### Invoice total integrity
`total_due` is **not** derived from line items — there are none. It is a single
scalar computed in a **widget**:

```dart
// dispatch_screen.dart:776
final newTotal = _toDollar(priceInput * effectiveCartons);
```

The formula is right, but it lives in presentation code, and the DB only checks
`amount_paid <= total_due`. Nothing ties the invoice to the goods shipped. A
manager can post `total_due = 1` for a 500-carton dispatch and the database
accepts it. *(P1-01)*

### Negative / zero quantity / negative price
- `cartons INTEGER CHECK (cartons >= 0)` — blocked at DB.
- `quantity_kg > 0`, `amount > 0` — blocked.
- `price_per_carton CHECK (>= 0)` — zero/negative rejected, but **no upper bound
  and no cross-field relationship to quantity** (P1-01).

### Invoice numbering
**None.** No invoice number, no sequence, no dispatch number — UUIDs only.
Nothing to duplicate, nothing to gap, and nothing to cite in a dispute (P2-01).

### Sales returns / cancellation
**Neither exists.** `PaymentStatus` is `unpaid | partial | paid`. No `cancelled`,
no `voided`, no `reversed`. A cancelled sale leaves its revenue in
`MAX(total_due)` permanently. A mistaken sale is corrected by deleting rows —
destroying the (nonexistent) audit trail.

---

## 6. Purchases

**Status: DOES NOT EXIST as a purchasing workflow.**

No purchase order, no goods receipt, no purchase invoice, no supplier entity,
no accounts payable.

What exists is **feed receipts** — an operational intake log:

```sql
-- feed_received
supplier TEXT,        -- free text, not a FK
invoice_number TEXT,  -- free text, never validated, never unique
price_per_kg NUMERIC(10,2),  -- optional, nullable
```

`SupplierAnalytics` (`phase1_analytics.dart:765`) groups by the free-text
supplier string. Consequences:

---

## 7. Inventory

**Status: quantity tracking only. Zero valuation.**

`inventory_items` has `quantity`. That is the entire model. `inventory_transactions`
holds `item_id, date, type, quantity, note, user_id` — and **no unit cost**.

**Absent**: unit cost, cost layer, warehouse, location, batch, lot, serial,
expiry, valuation method.

### FIFO
**Does not exist.** `feedCostOf()` is a naive weighted average:

```dart
// phase1_analytics.dart:57
cost += price * r.quantityKg;
```

It divides by total received kg regardless of what was consumed or when. It is
**not** FIFO and the code does not claim to be — but project planning docs
describe it as costing, which is where the doc-vs-code contradiction bites.

### The brief's FIFO test
> Purchase 100 @ $10, Purchase 100 @ $12, Sell 150 → 100 @ $10 + 50 @ $12.

**Cannot be run.** No sale-side cost consumption, no cost layer table, and
`inventory_transactions` records no unit cost. The only computable figure is
`15000/200 = $7.50` average — wrong under every standard method, and used to
value nothing anyway.

### `protect_inventory_quantity` — a real bug (ACC-003)
```sql
-- UNIFIED_schema.sql:3097
IF NEW.quantity IS DISTINCT FROM OLD.quantity THEN

---

## 8. Customers — the P0 bug

### Subledger formula

`recalc_customer_debt()` (`UNIFIED_schema.sql:1230`, and identically in
`UPGRADE_fix_recalc_customer_debt.sql`):

```sql
UPDATE customers
SET total_debt = COALESCE((
    SELECT SUM(total_due - amount_paid)
    FROM payments
    WHERE customer_id = v_cust AND deleted_at IS NULL
), 0)
```

This sums `(total_due - amount_paid)` over **every row** for the customer.

But `payments` stores the **full invoice total on every partial-payment row**,
and the app deliberately creates multiple rows per invoice
(`dispatch_screen.dart:235` — "إضافة دفعة تقسيط جديدة").

**Worked example.** Invoice = $1,000. Customer pays $300, then $200. Two rows
exist, both carrying `total_due = 1000`:

| row | total_due | amount_paid | contributes |
|---|---|---|---|
| 1 | 1000 | 300 | 700 |
| 2 | 1000 | 200 | 800 |

`total_debt` = **1500**. True outstanding = **500**. **Overstated 3×.**

Not a rounding artifact. This is the primary receivables figure, shown on the
customer screen, used to judge delinquency — and the trigger fires on every
INSERT/UPDATE/DELETE. It grows without bound as a customer pays in installments.
A customer who owes $500 can appear to owe $10,000.

**The codebase already knows the correct formula** — the SQLite path gets it
right:

```sql
-- payment_dao.dart:203-208  (CORRECT)
SELECT dispatch_id, MAX(total_due) as due, SUM(amount_paid) as paid
FROM payments WHERE dispatch_id IS NOT NULL ...
GROUP BY dispatch_id
```

So does `FinancialKpi.outstanding` (`phase1_analytics.dart:481-497`).

**Three implementations of outstanding balance exist:**
- SQLite: correct
- Dart analytics: correct
- Postgres trigger: **wrong, and authoritative**

The client and server disagree — and the server wins, because
`guard_customers_total_debt` actively *prevents* the client from correcting it.

### Aging / statements
**Neither exists.** No due-date buckets, no aging, no overdue flags.
`CustomerAnalytics.classification` (line 751) is `outstanding > 1000 ? 'attention'`
— a flat magic threshold, not aging.

### Overpayment
Blocked per-row by `CHECK (amount_paid <= total_due)`. But two rows of
`amount_paid = 1000` against a `total_due = 1000` invoice both pass → $2000
collected on a $1000 invoice. The Dart `isNowPaid` check is cumulative and
correct but advisory (P1-03).

---

## 9. Suppliers

**Not entities.** No `suppliers` table. `feed_received.supplier` is free text.
No AP, no statements, no aging, no balances.

---

## 10. Cash & Treasury

**Does not exist.** No cashboxes, no bank accounts, no funds, no transfers.

`PaymentMethod { cash | transfer | check | credit }` is a label on a collection,
not an account. Cash received is not distinguished from a check pending deposit.

**Consequence: you cannot answer "how much money is in the safe?"** — a
foundational question this system cannot answer.

---

## 11. Multi-Currency

**Cosmetic only.** `AppCurrency { dollar, lira }` — two hardcoded values in
`packages/core/lib/src/constants/enums.dart`. No USD, no EUR.

`exchange_rate NUMERIC(12,4)` is stored on `payments`, `expenses`, `revenue` —
and **never used in any calculation**. The only conversion in the codebase is in

---

## 14. Financial Reports

| Report | Status | Source |
|---|---|---|
| Trial Balance / General Ledger | **NO** | — |
| Balance Sheet / Income Statement / Cash Flow | **NO** | — |
| Customer / Supplier Statement | **NO** | — |
| Inventory Valuation | **NO** | no cost data exists |
| Stock Ledger | PARTIAL | quantity movements only |
| Sales Report | PARTIAL | `MAX(total_due)` per dispatch — right logic, wrong when the invoice is edited |
| Purchase Report | PARTIAL | `feed_received` only |
| Tax Report | **NO** | — |
| Production / Mortality / Feed KPIs | **YES** | strong pure-function analytics |
| Flock profitability | PARTIAL | `estimatedMargin` — acknowledged estimate in code |

The reports that exist **do read from the database**, not from UI totals — that
is correct and worth crediting. But there is no "posted vs draft" concept, so
"do reports read posted accounting data" is moot: there is only one state.

`estimatedMargin = collected - expenses` is **not profit**. It ignores COGS, feed
consumed, medications, labor, depreciation, opening balances, and inventory
change. A farm that sells its standing flock and buys feed shows a large
"margin". The code names it honestly; the dashboard presents it as a financial KPI.

---

## 15. Audit Trail

**`audit_log` is a dead table. It is never written to.**

- Table defined, with RLS and a SELECT grant for managers.
- **No INSERT statement anywhere** in Dart or SQL targeting it.
- **No trigger.** The schema defines `trg_calc_*`, `trg_validate_*`,
  `trg_update_flock_count`, `trg_recalc_customer_debt`, `trg_sync_tombstone_*`

---

## 16. Security

### Strengths (real, worth keeping)
- **RLS enabled on all 26 tables.** Not decorative.
- Passwords: bcrypt via `extensions.crypt(app_password_from_pin(pin), gen_salt('bf'))`.
- Auth uses GoTrue with synthetic email `'$uid@users.madjana.local'` and a
  `'madjana$' + pin` pepper — consistent client/server.
- **Login throttling**: `login_throttle`, `record_login_failure`,
  `check_login_allowed`, `throttle_exceeded`, configurable window and max attempts.
- **`prevent_self_privilege_escalation`** trigger.
- **`assert_current_is_manager_of`** in every admin RPC.
- `admin_create_user` forbids a manager from creating `system_admin`.
- Secrets via `.env` / `--dart-define`, no hardcoded keys. **Clean.**
- `SECURITY DEFINER SET search_path = public, pg_temp` on all definer functions.

### Weaknesses
- **PIN is 4 digits** (`CHECK (p_pin ~ '^[0-9]{4}$')`) = 10,000 combinations,
  against a 4-digit peppered bcrypt. Throttling is the only defence, and it is
  bypassable by distributed guessing. **PINs are not suitable as a sole
  credential for financial data access.** (P0-03)
- `pin_hash` also stored in `public.users`, readable via `users_select_self`.
- `find_user_by_phone` is `SECURITY DEFINER` and `GRANT`ed to **`anon`**. It
  returns a user UUID for any phone number, unauthenticated — a **user
  enumeration oracle** (P1-07).
- `app_password_from_pin`, `app_user_email`, `current_user_role`,
  `current_user_farm_id` also granted to **`anon`** (P1-08).
- **UI does not enforce roles.** `UserRole.canViewFinancials` / `.canEdit` exist
  and hide screens, but presentation code calls repositories with no guard. RLS
  is the real boundary — correct design, but the client flags give a false sense
  of enforcement and **no test proves RLS blocks a worker** (P1-09).

### No SQL injection
All access via the Supabase PostgREST client with query-builder methods. No
string-concatenated SQL in Dart. **Clean.**

### IDOR
RLS is farm-scoped on every operational table. Cross-farm reads blocked in the
database; `validate_flock_farm` blocks cross-farm *writes*. **Good.**

### The four roles
| Role | Can do | Verified where |
|---|---|---|
| `worker` | operational records for own farm; **no financials at all** | `ensure_operational_policies`; absent from `ensure_manager_policies` list |
| `manager` | full CRUD on own farm incl. all financial tables | `ensure_manager_policies` |
| `system_admin` | cross-farm everything | `is_system_admin()` in every policy |
| `Cashier` / `Accountant` | **do not exist** | — |

A farm owner wanting to give their accountant cashier rights and nothing else
cannot. It is a binary worker/manager split. Full detail in `SECURITY_AUDIT.md`.

---

## 17. Database Integrity

| Rule | Where | Verdict |
|---|---|---|
| `amount_paid <= total_due` | `payments` CHECK | Correct (per-row) |
| No future dates | 7 tables CHECK `date <= CURRENT_DATE` | Correct |
| Feed unit conversion | `check_feed_consumption_mode` | Correct |
| Conditional reason | `check_reason_other` | Correct |
| Cross-farm refs | 3 validate triggers | Correct |
| `total_debt` unforgeable | `guard_customers_total_debt` | Correct intent, **locks out the correct client because the server formula is wrong** |

---

## 18. Transactions — the second P0

I searched every DAO and `local_database.dart` for `.transaction(` and `batch(`:

```
flock_dao.dart:35:  await db.transaction((txn) async {
```

**One transaction, in the entire data layer** — and it is unrelated to money.
Every other write is a bare `await db.insert(...)` / `await db.update(...)`
against `LocalDatabase.database`, each auto-committed.

**`PaymentRepositoryImpl.save`** (payment_repository_impl.dart:36-69)
1. `paymentDao.insert` — payment written
2. `enqueueChange` — queue row written
3. `remoteDatasource.insert` — may throw
4. `updateSyncStatus` — may throw
5. `getTotalPaidForDispatch` — may throw
6. `dispatchDao.updatePaymentStatus` — **may throw, leaving a correct payment
   with a stale `payment_status` on the invoice**

**`PaymentRepositoryImpl.updateInvoiceForDispatch`** (87-117)
1. `updateInvoiceForDispatch` on all rows
2. loop: per-row remote update (N separate HTTP calls, each independently failable)
3. `updatePaymentStatus`

→ Partial remote update: some invoice rows at the new price, some at the old.

**`InventoryRepositoryImpl.adjustStock`** (97-100)
1. `localDao.saveItem(quantity: newQuantity)` — **balance already changed**
2. `insertTransaction` → itself two non-atomic remote calls

→ If step 2 fails, **stock is decremented with no movement record**, and the
remote insert is never queued for retry. Silent, permanent inventory loss.

**`SaveDispatchUseCase.call`** (save_dispatch_usecase.dart:47-48)
1. `repository.saveLocal(record)` — dispatch persisted
2. `await _openInvoice(dispatchId, record)` — wrapped in `catch (_) {}`

→ If the invoice fails, the dispatch exists with **no receivable**, and the
failure is swallowed. This is precisely the bug migration `20260926000300` was
written to backfill — the fix acknowledges the bug but does not prevent it.

**`OpeningBalanceRepositoryImpl.save`** (50-64): local save → flock count update
(`catch (_) {}`) → remote upsert (`catch (_) {}`). Three independent failure
modes, all silent.

**Fix:** introduce `db.transaction()` in the DAO layer and batch remote writes
behind a single retryable operation record. **Additive, low-risk** — no schema
change, no API change.

---

## 19. Concurrency

### Lost update on stock — real
```dart
// inventory_repository_impl.dart:75-84
final current = await _localDao.getById(itemId);          // READ
final newQuantity = isInput ? current.quantity + quantity : ...;  // COMPUTE
await _localDao.saveItem(result);                         // WRITE
```
Classic read-modify-write with no `version` check, no CAS, no transaction. Two
concurrent adjustments on the same item: one is silently lost. `version` exists on
`inventory_items` and is not used here.

### The negative-stock guard is local-only
```dart
if (!isInput && newQuantity < 0) {
  throw Exception('الكمية المطلوبة أكبر من المتوفر');
}
```
This checks the **local** balance. If another device already consumed the stock,
this device will happily drive the local balance negative, and the write will
propagate. The DB has **no `CHECK (quantity >= 0)`** on `inventory_items` (P0-04).

### Duplicate payments
No idempotency key on `PaymentRepositoryImpl.save`. Double-tap, or an offline
queue replay, creates two payment rows. The client is offline-first, so **queue
replay after a partial success is a normal expected event** — and there is no
protection. `idempotency_log` exists and is unused by this path.

### Sync-level concurrency — well handled
`version` + `previous_version` + `sync_conflicts` + tombstones + `sync_records_batch`
are genuinely well designed and covered by ~570 lines of tests. This is the
strongest part of the system. It protects *replication*; it does not protect
*business invariants*.

### Numbering
No invoice/payment/return numbers exist, so there is nothing to race on — and
nothing to reconcile against (P2-01).

---

## 20. Tests

| Package | Files | ~Lines |
|---|---|---|
| `packages/data/test` | 11 | ~3,800 |
| `packages/core/test` | 3 | ~330 |
| `apps/desktop/test` | **0** | 0 |
| `apps/mobile/test` | **0** | 0 |

### What IS covered — and it is good
- **OCC / sync queueing** (`daos_occ_test.dart`, `daos_rest_test.dart`): 30+ tests
  asserting exact payloads, `previous_version` values, sync-status transitions.
- **Repository implementations** (`repositories_impl_test.dart`,
  `repositories_impl_rest_test.dart`): 1,082 lines — offline/online paths, merge
  precedence.
- **Sync engine** (`sync_repository_test.dart`): 569 lines — conflicts, tombstones,
  batching, reconciliation.
- **Backup/restore** (`backup_service_test.dart`): checksum verification,
  corruption rejection, pruning.
- **Domain** (`egg_calculator_test.dart`, `flock_model_test.dart`,
  `mortality_regression_test.dart`).

This is genuinely above-average discipline for the sync layer. Real testing, not
test theatre.

### What is NOT covered — everything that matters financially
| Area | Coverage |
|---|---|

---

## 21. Business Scenario Testing (§34)

### Scenario 1 — Opening stock 100 @ $10, cash sale 20 @ $15
Expected: Revenue 300, COGS 200, GP 100, Inv 80, InvValue 800, Cash +300.

| Metric | Result |
|---|---|
| Revenue | **Can compute.** `MAX(total_due)` = 300. ✅ numerically right |
| COGS | **Does not exist.** No cost attached to any sale. |
| Gross Profit | **Does not exist.** `estimatedMargin` = collected − expenses = 300 − 0 = 300. Reports **300 as "margin" when true margin is 100.** |
| Inventory 80 | ❌ Dispatch does **not** touch `inventory_items`. Egg "stock" is a widget-level subtraction (`dispatch_screen.dart:70`). |
| Inventory Value 800 | ❌ Impossible — no cost layer exists. |
| Cash +300 | ❌ Impossible — no cash account exists. |

**3 of 6 pass; 3 are structurally impossible. The headline number presented as
profit is overstated by 200%.**

### Scenario 2 — Credit sale 20 @ $15
- AR +300: ✅ **if** `SaveDispatchUseCase._openInvoice` succeeds — and it is
  wrapped in `catch (_) {}`, so it can silently produce AR = 0 (P0-05).
- Cash unchanged: **N/A** — no cash account, so nothing *can* wrongly change.
  Vacuously true, not a passing test.
- Revenue 300: ✅ same caveat.
- COGS / Inventory: ❌ absent.

### Scenario 3 — Customer pays $150
- AR −150: ✅ **in the Dart analytics** (correct grouping). ❌ **in the Postgres
  trigger** — a single payment on a fresh invoice happens to be right, but the

---

## 23. Missing Features

None of these are "bugs" — they are absent product surface, listed so the
category is explicit.

**Foundational (absent — not "partial"):**
Chart of Accounts · General Ledger · Journal Entries · Trial Balance · Balance
Sheet · Income Statement · Cash Flow · Fiscal Periods & Closing · Purchase Orders ·
Goods Receipt · Purchase Invoices · Accounts Payable · Suppliers as entities ·
Cashboxes/Bank/Treasury · Inventory Valuation · Cost Layers (FIFO/AVG) ·
Warehouses · Batches/Lots/Serials/Expiry · Fixed Assets & Depreciation · Tax ·
Document Numbering · Sales Returns · Purchase Returns · Credit Notes ·
Void/Cancel · Approval workflow · Aging · Reconciliation · Budgets · Cost
Centres · Manufacturing.

**Uniquely absent, and important for this domain:**
- **Flock cost accounting** — `flocks` has no `unit_cost`. You cannot know what a
  flock cost to raise.
- **Egg inventory as a real asset** — dispatched eggs decrement nothing.
- **Feed inventory as a real asset** — received feed increments nothing; feed is
  consumed from an *average rate*, not from stock.

This means **the two largest cost and revenue items in a poultry operation are
both outside the inventory system entirely.**

---

## 24. ERP Gap Matrix

| Module | Implemented | Correct | Tested | Production Ready | Issues |
|---|---|---|---|---|---|
| Accounting | NO | NO | NO | **NO** | Subsystem absent |
| Sales | PARTIAL | PARTIAL | NO | **NO** | No returns, no cancel, no COGS, no atomicity |
| Purchases | NO | NO | NO | **NO** | Free-text feed receipts only |
| Inventory | PARTIAL | **NO** | NO | **NO** | Quantity only; no valuation; write path broken |
| Customers | PARTIAL | **NO** | NO | **NO** | **ACC-001 over-counts debt** |
| Suppliers | NO | NO | NO | **NO** | Free text |
| Treasury | NO | NO | NO | **NO** | No cash/bank/fund |
| Multi-Currency | PARTIAL | NO | NO | **NO** | Conversion in UI; no FX accounting |
| Tax | NO | NO | NO | **NO** | — |
| Fixed Assets | NO | NO | NO | **NO** | — |
| Reports | PARTIAL | PARTIAL | NO | **NO** | No GL/statements/reconciliation |
| Audit | **NO** | NO | NO | **NO** | Table never written |
| Security | PARTIAL | PARTIAL | NO | **NO** | Strong RLS; 4-digit PIN; no tests |
| Flocks / Production | YES | YES | PARTIAL | **PARTIAL** | Strongest domain area |
| Feed Ops | YES | YES | PARTIAL | **PARTIAL** | Not linked to stock |
| Sync Engine | YES | YES | YES | **YES** | Genuinely production-grade |

Scale: YES = complete and evidenced · PARTIAL = real implementation, materially
incomplete · NO = absent · UNKNOWN = not provable from code. **No percentages —
they would imply precision this codebase cannot support.**

---

## 26. Answers to the 20 Questions (§38)

| # | Question | Answer |
|---|---|---|
| 1 | Is Double Entry safe? | **N/A — no double entry exists.** No CoA, no journal, no GL. |
| 2 | Is Posting safe? | **N/A — no posting concept.** All records are immediately live and mutable. |
| 3 | Is Reversal correct? | **NO — no reversal exists.** Undoing a sale means deleting or hand-editing rows. |
| 4 | Is Invoice → GL correct? | **N/A — no GL.** Invoice → *customer debt*: **NO** (ACC-001). |
| 5 | Is Invoice → Inventory correct? | **NO.** Dispatch does not touch `inventory_items`. Egg "stock" is a widget-level subtraction (`dispatch_screen.dart:70`). |
| 6 | Is Payment → GL correct? | **N/A.** Payment → debt: **NO** (ACC-001). Payment → cash: **impossible**, no cash account. |
| 7 | Are Returns correct? | **NO — returns do not exist.** |
| 8 | Is FIFO correct? | **NO — FIFO does not exist.** No cost layer, no unit cost on movement. `feedCostOf` is a naive average and values nothing. |
| 9 | Is Multi-Currency correct? | **NO.** Rate stored, never used; conversion in the UI; no FX gain/loss, no historical rates, no revaluation. |
| 10 | Are Customer/Supplier balances correct? | Customer: **NO** (ACC-001). Supplier: **NO** (no supplier entity). |
| 11 | Is Inventory GL reconciliation correct? | **NO — no Inventory GL and no valuation exist.** |
| 12 | Is Cash GL reconciliation correct? | **NO — no Cash GL exists.** |
| 13 | Is Fiscal Period safe? | **NO — no fiscal periods exist.** Only `date <= CURRENT_DATE`, which allows free back-dating. |
| 14 | Is the Audit Trail real? | **NO.** `audit_log` is never written. No trigger, no insert. |
| 15 | Are transactions atomic? | **NO.** One `db.transaction()` in the entire data layer (in `flock_dao.dart`, unrelated to money). |
| 16 | Are duplicate operations protected? | **PARTIAL.** UUID-per-row prevents ID collisions; no idempotency key prevents duplicate payments on replay. |
| 17 | Is concurrency protected? | **PARTIAL.** Excellent for sync replication; **absent** for business invariants (lost update on stock, no negative-stock DB check). |

---

## 27. Roadmap

### Phase 1 — Critical (all small, additive, low-risk)

| # | Fix | Size | Why first |
|---|---|---|---|
| 1 | **ACC-001** — rewrite `recalc_customer_debt()` to group by `dispatch_id` using `MAX(total_due)` / `SUM(amount_paid)`, exactly as `payment_dao.dart:203` does. + backfill | ~10 lines SQL | Wrong customer balances, visible daily, growing without bound. Cheapest severe fix in the repo. |
| 2 | **ACC-002** — wrap `adjustStock` in a single `db.transaction()`; queue the movement record for retry on remote failure | ~20 lines | Silent permanent stock loss. |
| 3 | **ACC-003** — replace the two-call `insertTransaction` with one `SECURITY DEFINER` RPC doing both (or relax the trigger to allow a quantity change when a movement row exists in the same transaction) | ~40 lines | Online inventory and item editing are currently broken. |
| 4 | **ACC-005** — add `CHECK (quantity >= 0)` to `inventory_items` | 1 line | Stop negative stock at the source. |
| 5 | **ACC-004** — raise PIN length to 6+ (or password + optional MFA for `system_admin`), reusing the existing `admin_reset_pin` RPC | migration | 10⁴ credentials fronting all financial data. |
| 6 | **ACC-006** — stop swallowing the invoice exception in `_openInvoice`; surface it and mark the dispatch `invoice_status='missing'`, reconciled by the existing backfill logic | ~15 lines | Sales with no receivable. |
| 7 | **INT-006** — revoke `anon` from `find_user_by_phone`; route login through a single RPC that returns nothing on failure | 2 lines | Unauthenticated user enumeration. |
| 8 | Add **three** tests: multi-payment debt recalc, atomic rollback on injected failure, and a worker-is-blocked-from-`payments` RLS test | ~200 lines | Prevents recurrence. Nothing else on this list is protected without these. |

### Phase 2 — Commercial Accounting
Requires a decision from you first, because it is architectural.

**Option A — stay a farm-operations app.** Say so explicitly, and fix the
*reporting honesty*: relabel `estimatedMargin` as an estimate everywhere, add a
real cash total (opening + collections − expenses), and add customer aging and
statements on top of the existing `payments` data. Weeks, not months — and it
would genuinely serve most single-farm customers.

**Option B — become a real accounting system.** Then these are not optional and
must precede any Phase 3 work: Chart of Accounts · General Ledger with balanced
journals · a Posting service (draft → posted, posted immutable, reversals only) ·
Fiscal periods · Trial Balance · Balance Sheet and Income Statement · Inventory
valuation · Accounts Payable · Cashboxes/Bank · Tax · a genuine audit trail.
That is a new product, and I would not attempt it by editing the existing code —
but **nothing in the sync engine, RLS model, or analytics layer blocks it**, and
those are genuinely reusable.

**Do not** let Phase 3 begin before Phase 1 is closed.

### Phase 3 — ERP Features
CRM · supplier management · purchasing · multi-warehouse · pricing tiers and
promotions · budgets · cost centres · batch/lot/expiry for medications (a real
regulatory need for veterinary drugs) · flock unit cost · manufacturing.
**Only after Phase 1 and a Phase 2 decision.**

---

## 28. What I Did Not Do

No file was modified. No commit, branch, migration, or database reset. No
configuration change. Only new files under `docs/`, which is the requested
deliverable. All existing `docs/` content is untouched.

## 29. Where to Read Next
- `ACCOUNTING_INTEGRITY_AUDIT.md` — the P0s in full, with worked examples
- `SECURITY_AUDIT.md` — the RLS model mapped table by table
- `ERP_GAP_MATRIX.md` — feature-by-feature against commercial accounting
- `TEST_COVERAGE_GAPS.md` — what is tested, what is not, and the pattern behind it

| 18 | Is authorization correct? | **PARTIAL.** RLS is real, farm-scoped, correct. Gaps: 4-digit PIN, `anon` grants on enumeration functions, no cashier/accountant roles, no authorization tests. |
| 19 | Do the tests prove it? | **NO.** ~4,100 lines cover sync/OCC/repos/backup. **Zero** for receivables, atomicity, concurrency, RLS, reconciliation. The P0s are exactly the untested surface. |
| 20 | What is missing for commercial ERP? | See §27. |


---

## 25. Production Readiness

### As a commercial **accounting** product: **Not ready. Not close.**
You cannot produce a trial balance, a balance sheet, or an income statement.
"What is the farm worth?" is unanswerable: no inventory valuation, no fixed
assets, no receivables control account, no payables.

### As what it actually is — farm operations with receivables: **Nearly ready, with 3 blockers.**

**It is a good application.** The sync engine, the RLS model, the pure-function
analytics, the DB-level domain constraints, and the test discipline around
infrastructure are all real and, in places, better than commercial software I
have audited. The Arabic-first UX, offline-first mobile design, and domain
expertise (withdrawal periods, feed conversion, mortality→flock cascade) are
genuine differentiators.

**But three P0s stand between it and production:**
1. **ACC-001** — customer debts are wrong, and the client is architecturally
   prevented from fixing them. Visible to every user, every day. Also the easiest
   fix in this document: change one `SUM` to the grouped query the SQLite path
   already uses.
2. **ACC-002 / ACC-003** — online inventory is broken (the app's write path is
   blocked by the app's own trigger) and offline inventory loses stock on failure.
3. **ACC-004** — a 4-digit PIN fronts the entire financial dataset.

**The uncomfortable pattern:** the three hardest problems — receivables
correctness, transactional integrity, and auditability — are the three with
**zero test coverage**, and also the three a competent accountant would raise in
the first ten minutes of an evaluation. The best-tested code is the code that was
already correct.

  *total* the trigger leaves behind is wrong (§8 worked example).
- Cash +150: ❌ no cash account.

### Scenario 4 — Return 5 units
**The operation does not exist.** No return document, no credit note, no
reversal. There is no code path to test. To correct a 5-carton over-dispatch the
user must delete the dispatch (destroying the nonexistent audit trail) or
hand-edit a payment row's `amount_paid`, which the recalc trigger will propagate
as a debt change. **There is no safe correction path.**

### Scenario 5 — Transaction fails after inventory update
Expected: NO partial state.
Actual: **partial state, guaranteed.** From `inventory_repository_impl.dart:97-103`:
the local balance is written first, the transaction record second, no transaction
and no retry queue for the record. An exception at line 100 leaves stock
decremented with no ledger entry. This is not a race — it is the ordinary
failure path.

---

## 22. Critical Bugs (ranked)

| ID | Sev | Location | Issue |
|---|---|---|---|
| **ACC-001** | **P0** | `UNIFIED_schema.sql:1230` `recalc_customer_debt()` | `SUM(total_due - amount_paid)` over all rows over-counts receivables on every multi-payment invoice. Server-side, authoritative, client-locked out. |
| **ACC-002** | **P0** | `inventory_repository_impl.dart:97` | `adjustStock` not atomic → stock loss with no ledger entry on any failure. |
| **ACC-003** | **P0** | `supabase_inventory_datasource.dart:41-47` + trigger `:3097` | App's own inventory write path is rejected by the app's own trigger; online stock sync and item editing broken. Two non-atomic remote calls. |
| **ACC-004** | **P0** | `UNIFIED_schema.sql:2300` | 4-digit PIN = 10⁴ credentials fronting all financial data. |
| **ACC-005** | **P0** | `inventory_items` | No `CHECK (quantity >= 0)` — negative stock propagates from a stale device. |
| **ACC-006** | **P0** | `save_dispatch_usecase.dart:47` | Dispatch commits, invoice creation is `catch (_) {}` → sale with no receivable. |
| INT-001 | P1 | `audit_log` | Never written. No trigger, no insert. Docs claim a trigger exists. |
| INT-002 | P1 | `PaymentRepositoryImpl.save` | Payment committed before invoice status update; no idempotency key → duplicate payments on replay. |
| INT-003 | P1 | `updateInvoiceForDispatch` | N sequential remote updates; partial application leaves mixed prices. |
| INT-004 | P1 | `feed_received` → `inventory_items` | Feed receipt does not post stock. Paid inventory untracked. |
| INT-005 | P1 | `dispatch_screen.dart:706` | FX conversion in the widget; rate unvalidated; no FX gain/loss, no historical rates. |
| INT-006 | P1 | `find_user_by_phone` granted to `anon` | Unauthenticated user enumeration + UUID disclosure. |
| INT-007 | P1 | `UserRole` | No cashier/accountant role; client guards unenforced and untested. |
| INT-008 | P1 | `CHECK (amount_paid <= total_due)` | Blocks credit notes; per-row so cumulative overpayment passes. |
| SEC-001 | P1 | `feed_received.price_per_kg` nullable | Understated cost is *reported* via `unpricedShipments` (good) but not blocked. |
| CODE-001 | P2 | 5 files, `catch (_) {}` | Silent failures across revenue/expense/opening-balance/auth paths. |
| CODE-002 | P2 | no document numbering | No invoice/receipt/payment numbers anywhere. |
| CODE-003 | P2 | UI → Repository direct | ~15 feature areas bypass the 6 use cases; no business-logic test seam. |
| CODE-004 | P2 | `docs/` vs code | `audit_trigger_function`, FIFO, and "accounting" claims unsupported by code. |

| `recalc_customer_debt` correctness | **NONE** — the P0 bug is untested |
| Transactional atomicity / rollback | **NONE** — no test asserts partial-failure state |
| Inventory negative-stock race | **NONE** |
| Overpayment / multi-payment invoice | **NONE** |
| Reconciliation (any) | **NONE** |
| **RLS enforcement** (worker cannot read financials) | **NONE** — no security test at all |
| **Concurrency** (two devices, same item) | **NONE** |
| Any presentation/widget test | **NONE** (0 files in both apps) |

**The central pattern of this audit:** every subsystem that has tests is
`sync/infra`; every subsystem with **no** tests is `money/business`. The testing
effort went to the part that was already correct, and the part that was not
touched at all. That is why the P0 in §8 shipped.

Detail in `TEST_COVERAGE_GAPS.md`.

| Quantity not directly editable | `protect_inventory_quantity` | **Breaks the app's own write path** (P0-02) |
| `current_count` on mortality | `update_flock_count_on_mortality` | Correct |
| Role escalation | `prevent_self_privilege_escalation` | Correct |

**No unique constraints on business keys.** No exclusion constraints.

### `CHECK (amount_paid <= total_due)` blocks legitimate credit notes
A **negative payment** is impossible, so a credit note or overpayment refund can
never be recorded. The model cannot express "we owe the customer $50" (P1-10).

  — and **zero** `trg_audit_*`.
- `DATABASE_SCHEMA_GUIDE.md:145` documents an `audit_trigger_function()` that
  **does not exist in any migration file**. Doc-vs-code contradiction, logged.

Partial substitute: `payments` and `expenses` carry `manager_id`, and
`sync_changes` retains old/new payloads. That answers "who" for two tables and
gives partial before/after for sync. It answers nothing for `egg_dispatch`,
`egg_production`, `mortality`, `feed_*`, `inventory_items`, `customers`, `flocks`.

**You cannot answer:** who cancelled this invoice, who changed this price, who
altered this customer's balance, who adjusted this stock. (P1-06)

a widget:

```dart
// dispatch_screen.dart:706
double _toDollar(double value) =>
    _currency == AppCurrency.lira && (_exchangeRate ?? 0) > 0
        ? value / _exchangeRate! : value;
```

The converted dollar figure is what gets stored, so `total_due`/`amount_paid` are
both USD and `currency`/`exchange_rate` are decorative metadata.

- No historical rate table — the rate lives on the document row.
- No realized FX gain/loss. No unrealized revaluation. No period-end revaluation.
- **No rounding policy.** `NUMERIC(16,8)` was chosen (per
  `UPGRADE_numeric_precision.sql`, to fix a 389950-vs-390000 rounding bug) —
  defensible, but 8 decimals is not a documented monetary policy.

A rate entered as 89,000 instead of 89,500 silently misprices an entire invoice
and nothing detects it (P1-05).

---

## 12. Tax

**Does not exist.** No rates, no tax accounts, no VAT, no inclusive/exclusive
pricing, no reports. `Expenses.amount` is tax-inclusive by accident.

---

## 13. Fixed Assets

**Does not exist.** No asset register, no depreciation, no disposal.
`revenue.category` has `equipment`, which records an equipment sale as revenue
and nothing more.

    RAISE EXCEPTION 'لا يمكن تعديل الرصيد مباشرة. استخدم معاملات المخزون';
```

This fires on **any** UPDATE touching quantity. But the app's own remote path does
exactly that:

```dart
// supabase_inventory_datasource.dart:43-47
await _api.from('inventory_transactions').insert(tx.toJson()).run();
await _api.from('inventory_items')
    .update({'quantity': newQuantity}).eq('id', tx.itemId).run();
```

**The trigger rejects it.** Online stock adjustment is broken; only the local
SQLite path (no such trigger) succeeds and silently diverges from the server.
Two non-atomic remote calls — a textbook partial write.

Worse: `updateItem()` sends the full `item.toJson()` including `quantity`, so
**editing an item's name or notes online also throws the trigger**. The entire
`inventory_items` UPDATE path is unusable against the server. (P0-02)

- "Al Waleed" and "alwaleed " are two different suppliers.
- `price_per_kg` is nullable — and the code handles this **honestly**:
  `FeedCost` tracks `unpricedShipments` and `unpricedKg` separately so the
  understatement is visible rather than hidden. Good engineering; crediting it.
- `feed_received` has **no link to `inventory_items`**. Receiving 1000 kg of feed
  does not increment any stock ledger (P1-02).

There is no stock valuation: feed bought at $12/kg and feed bought at $4/kg are,
to this system, the same kilograms.


It is a **vertical farm-operations app with a lightweight receivables ledger**.
It is not an ERP accounting engine, and it is not attempting to be one.

So most requested sections (Accounting Core, Journal Lifecycle, Purchase Audit,
FIFO Engine, Fixed Assets) are **not "PARTIAL" — they are "NO"**: the subject
matter does not exist. Calling them gaps would imply a missing feature rather
than a different product category.

I audited what *does* exist, and found real defects in it.

---

## 1. Executive Summary

### What is real and works
- A coherent **offline-first sync engine**: local SQLite as source of truth for
  writes, Supabase as replica, with sync_queue, tombstones, optimistic
  concurrency `version` columns, and conflict detection
  (`packages/data/lib/src/repositories/sync_repository_impl.dart`, 1022 lines).
- **RLS actually enabled on all 26 tables**, roles `worker / manager /
  system_admin`, farm-scoped policies generated by `ensure_operational_policies()`
  and `ensure_manager_policies()`.
- **Real domain invariants enforced in the database, not just UI:**
  - `CHECK (amount_paid <= total_due)` on payments
  - `CHECK (date <= CURRENT_DATE)` on 7 tables
  - `check_feed_consumption_mode` — bags mode must equal `bags_count * 24` kg
  - `check_reason_other` — conditional NOT NULL
  - `validate_flock_farm()` / `validate_dispatch_refs()` / `validate_payment_refs()`
    — cross-farm reference injection blocked
  - `guard_customers_total_debt()` — clients cannot forge `total_debt`
  - `protect_inventory_quantity()` — quantity not directly editable
  - `prevent_self_privilege_escalation`
  - `login_throttle` + `record_login_failure` / `check_login_allowed`
  - bcrypt via `app_password_from_pin` + `gen_salt('bf')`
- Analytics (`packages/core/lib/src/services/phase1_analytics.dart`, ~1400 lines)
  is **pure functions, no DB access, no side effects**, and is *correctly*
  careful about double-counting partial payments.

### What is genuinely broken
1. **P0 — `recalc_customer_debt()` over-counts receivables on every
   multi-payment invoice.** Most damaging bug in the codebase (§8, ACC-001).
2. **P0 — no transaction anywhere in the Dart data layer.** Every repository
   method is a sequence of independently-committed sqflite writes (§18).
3. **P1 — `audit_log` is never written to.** No trigger, no insert, anywhere
   (§15, INT-001).
4. **P0 — the app's own inventory write path is rejected by the app's own
   trigger** (§7, ACC-003).
