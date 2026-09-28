# YASeen ERP — Accounting Integrity Audit

**Companion to** `FULL_CODE_AUDIT.md`. READ-ONLY audit; no files modified.

**Scope note:** there is no double-entry accounting engine in this codebase, so
this document audits the financial invariants that *do* exist — receivables,
transactional integrity, stock integrity, and auditability — and states plainly
where an invariant is **undefined** because the underlying subsystem is absent.

---

## ACC-001 — P0 — Customer receivables are systematically over-counted

**Module:** Customers / Receivables
**File:** `supabase/migrations/UNIFIED_schema.sql:1230-1268`
**Function:** `public.recalc_customer_debt()` (trigger `trg_recalc_customer_debt`)
**Duplicate in:** `supabase/migrations/UPGRADE_fix_recalc_customer_debt.sql`

### Problem
```sql
UPDATE customers
SET total_debt = COALESCE((
    SELECT SUM(total_due - amount_paid)
    FROM payments
    WHERE customer_id = v_cust AND deleted_at IS NULL
), 0)
```

The function sums `(total_due - amount_paid)` across **every** `payments` row for
the customer. It assumes one row per invoice. The application does not behave
that way: it deliberately creates **one row per collection** against the same
invoice, and each row carries the **full invoice total** in `total_due`.

### Why it matters
`customers.total_debt` is *the* receivables figure in this system. It is shown on
the customer screen, it is protected from client correction by
`guard_customers_total_debt`, and it drives delinquency decisions. The error is
not a constant offset — it **scales with the number of instalments**, so the
worst-affected customers are exactly the ones paying most reliably.

### Real-world scenario
Invoice $1,000. Customer pays $300, then $200.

| row | total_due | amount_paid | contributes |
|---|---|---|---|
| 1 | 1000 | 300 | 700 |
| 2 | 1000 | 200 | 800 |

- `total_debt` reported: **$1,500**
- True outstanding: **$500**
- **Overstated 3×**

A customer paying in 5 instalments of $200 on a $1,000 invoice shows a debt of
$4,000. A long-standing customer who has paid everything still shows a large
balance, because the last invoice row still carries `total_due`.

### Current behaviour
`total_debt` = Σ over rows of (invoice total − that row's payment).

### Expected behaviour
`total_debt` = Σ over **invoices** of (invoice total − Σ payments on that invoice),
with standalone (no `dispatch_id`) rows treated as their own invoice.

### The codebase already contains the correct formula
```sql
-- packages/data/lib/src/datasources/local/daos/payment_dao.dart:203-208
SELECT dispatch_id, MAX(total_due) as due, SUM(amount_paid) as paid
FROM payments
WHERE dispatch_id IS NOT NULL AND deleted_at IS NULL
GROUP BY dispatch_id
HAVING SUM(amount_paid) < MAX(total_due)
UNION ALL
SELECT id, total_due, amount_paid
FROM payments
WHERE dispatch_id IS NULL AND amount_paid < total_due ...
```

`FinancialKpi.outstanding` (`phase1_analytics.dart:481-497`) does the same in
Dart. **Three implementations exist; two are correct; the authoritative one is
wrong.** And because `guard_customers_total_debt` blocks any client-side write
to the column, the app cannot self-heal.

### Recommended fix
Replace the subquery in `recalc_customer_debt()` with the grouped form above
(a `CREATE OR REPLACE FUNCTION` in a new additive migration — no schema change,
no API change, no app change), then run a one-off backfill:

```sql
UPDATE customers c SET total_debt = COALESCE((
  SELECT SUM(due - paid) FROM (
    SELECT dispatch_id, MAX(total_due) AS due, SUM(amount_paid) AS paid
    FROM payments WHERE customer_id = c.id AND deleted_at IS NULL
      AND dispatch_id IS NOT NULL GROUP BY dispatch_id
    UNION ALL
    SELECT id, total_due, amount_paid FROM payments
    WHERE customer_id = c.id AND deleted_at IS NULL AND dispatch_id IS NULL
  ) t

## ACC-002 — P0 — Inventory adjustment is not atomic → stock loss

**Module:** Inventory
**File:** `packages/data/lib/src/repositories/inventory_repository_impl.dart:69-106`
**Function:** `InventoryRepositoryImpl.adjustStock`

### Problem
```dart
final current = await _localDao.getById(itemId);        // 1. read
final newQuantity = isInput ? current.quantity + quantity
                            : current.quantity - quantity;  // 2. compute
...
await _localDao.saveItem(result);                       // 3. WRITE quantity
try {
  await _remoteDatasource.insertTransaction(tx, newQuantity: newQuantity); // 4.
} catch (_) {
  // Offline: saved locally
}
```

Step 3 **commits the new balance**. Step 4 records the movement and pushes it
remotely. There is no `db.transaction()` and no retry queue for the movement
record.

### Why it matters
This is the "Inventory decreased BUT no movement record" state from the brief —
and it is the **ordinary failure path**, not a rare race. Any network error at
step 4 leaves the local stock permanently decremented with no ledger entry. The
comment `// Offline: saved locally` is misleading: what is saved locally is the
*balance*, not the transaction, and the transaction is never enqueued for replay.

### Real-world scenario
A manager removes 50 vaccine vials offline, then loses signal.
`_localDao.saveItem` succeeds. `_remoteDatasource.insertTransaction` throws and is
swallowed. Local stock shows 50 fewer vials; `inventory_transactions` has no row;
the server still shows the old quantity. On reconnect nothing reconciles it,
because only the *balance* was local — there is no queued transaction to push.
**The discrepancy is permanent and invisible.**

### Current vs expected
- Current: balance is authoritative; the movement record is best-effort and lossy.
- Expected: balance and movement commit together, atomically, and the remote push
  is either queued as a retryable operation or rolled back.

### Recommended fix
1. Wrap the local writes in `db.transaction()` so balance + transaction +
   `enqueueChange` are one unit.
2. Better: introduce a single `SECURITY DEFINER` RPC on the server that inserts
   the movement and updates the balance together (this also fixes ACC-003).
3. Never compute a balance client-side and write it; send the *delta* and let the
   database derive the balance. This removes the lost-update class entirely.

### Regression risk
**Low.** `LocalDatabase.enqueueChange` already exists and is used by every other
DAO, so the pattern is established.

---

## ACC-003 — P0 — The app's own inventory write path is rejected by the app's own trigger

**Module:** Inventory
**Files:** `packages/data/lib/src/datasources/remote/supabase_inventory_datasource.dart:33-47`
and `supabase/migrations/UNIFIED_schema.sql:3097-3110`

### Problem
The trigger:
```sql
CREATE OR REPLACE FUNCTION public.protect_inventory_quantity() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.quantity IS DISTINCT FROM OLD.quantity THEN
        RAISE EXCEPTION 'لا يمكن تعديل الرصيد مباشرة. استخدم معاملات المخزون';
    END IF;
    RETURN NEW;
END; $$;
```

The application's remote adapter:
```dart
await _api.from('inventory_transactions').insert(tx.toJson()).run();      // ok
await _api.from('inventory_items')
    .update({'quantity': newQuantity}).eq('id', tx.itemId).run();         // THROWS
```

`adjustStock` calls exactly this. **Every online stock adjustment fails**, and the
exception is swallowed by the `catch (_)`, so the local cache advances while the

---

## ACC-004 — P0 — A 4-digit PIN fronts the entire financial dataset

**File:** `supabase/migrations/UNIFIED_schema.sql:2300`
**Rule:** `IF p_pin !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';`

The sole credential is a **4-digit PIN** (10,000 combinations), transformed by a
4-character static pepper (`'madjana$'`, `supabase_auth_datasource.dart:305`) and
stored as bcrypt. Bcrypt protects the *storage*, not the *keyspace*. Defence
against guessing is `login_throttle`.

**Why it matters:** one compromised PIN exposes every customer's balance, every
payment amount, and every farm's revenue. A 6-digit PIN raises the keyspace 100×
for a one-line change.

**Fix:** (1) immediate — raise the minimum to 6 digits, require 8 for
`system_admin`; `admin_reset_pin` already exists for the migration path.
(2) near-term — key throttling on IP + device as well as phone, with exponential
backoff. (3) better — replace the PIN with a real password for `manager` and
`system_admin` while keeping the PIN flow for field `worker`s on shared devices;
GoTrue already supports this, so it is a policy change, not a re-architecture.

**Regression risk:** **Medium** — existing 4-digit PINs stop working and must be
reset. Do it as a deliberate, announced migration.

---

## ACC-005 — P0 — No database-level guarantee against negative stock

**File:** `supabase/migrations/UNIFIED_schema.sql` (`inventory_items`)

The only negative-stock guard is client-side:
```dart
if (!isInput && newQuantity < 0) { throw Exception('الكمية المطلوبة أكبر من المتوفر'); }
```
It checks the **local** balance. `inventory_items` has **no `CHECK (quantity >= 0)`**.

The app is offline-first and multi-device by design. If another device consumed
the stock first, this device's local balance is stale and will go negative — and
the write propagates to the server, which accepts it.

**Fix:** add `CHECK (quantity >= 0)` and reject with an error the UI can surface
("stock was consumed on another device — refresh"). One line; closes the class.

**Regression risk:** **Low**, but run a data check first — this may surface
existing negative rows.

---

## ACC-006 — P0 — A dispatch can commit with no receivable

**File:** `packages/core/lib/src/usecases/save_dispatch_usecase.dart:40-95`
**Functions:** `SaveDispatchUseCase.call`, `SaveDispatchUseCase._openInvoice`

```dart
final dispatchId = await repository.saveLocal(record);   // committed
await _openInvoice(dispatchId, record);                  // catch (_) {}
```
```dart

---

## ACC-007 — P1 — No transaction anywhere in the money path

**Files:** all of `packages/data/lib/src/datasources/local/daos/*.dart`,
`packages/data/lib/src/repositories/*_impl.dart`

### Evidence
A search for `.transaction(` and `batch(` across every DAO and
`local_database.dart` returns exactly one hit:
```
flock_dao.dart:35:  await db.transaction((txn) async {
```
That one is unrelated to money. Every other write is a bare `await db.insert()` or
`await db.update()` against `LocalDatabase.database`, each auto-committed.

### Non-atomic sequences touching money

**`PaymentRepositoryImpl.save`** (`payment_repository_impl.dart:36-69`)
1. `paymentDao.insert` — payment written
2. `enqueueChange` — queue row written
3. `remoteDatasource.insert` — may throw
4. `updateSyncStatus` — may throw
5. `getTotalPaidForDispatch` — may throw
6. `dispatchDao.updatePaymentStatus` — **may throw, leaving a correct payment
   with a stale `payment_status` on the invoice**

**`PaymentRepositoryImpl.updateInvoiceForDispatch`** (`87-117`) — N sequential
remote updates, each independently failable, then a status update. Partial
application leaves some invoice rows at the new price and some at the old.

**`InventoryRepositoryImpl.adjustStock`** (`97-100`) — see ACC-002.

**`OpeningBalanceRepositoryImpl.save`** (`50-64`) — local save → flock count
update (`catch (_) {}`) → remote upsert (`catch (_) {}`). Three independent
failure modes, all silent.

### The critical integrity state this creates
**Payment exists BUT customer balance didn't change.** Step 1 commits the payment
locally. If the process dies before the server push, the payment sits in the local
queue but the server-side `recalc_customer_debt` trigger has not fired, so the
server balance is stale until the queue drains — and if the queue entry is lost,
the payment never reaches the server at all.

### Recommended fix
Introduce a `LocalDatabase.transaction(fn)` helper and adopt it in every DAO that
writes more than one row, pairing each business write with its `enqueueChange` so
the two are always written together. Mechanical, additive, no schema or API
impact. The pattern to copy already exists in `flock_dao.dart`.

### Regression risk
**Low.** sqflite transactions are well-understood.

---

## ACC-008 — P1 — `audit_log` is never written

**File:** `supabase/migrations/UNIFIED_schema.sql` (table + policies only)

### Evidence
- The table exists with RLS, an `audit_select_manager` policy, and
  `GRANT SELECT, INSERT ON audit_log TO authenticated`.
- **No `INSERT INTO audit_log` anywhere** in the Dart codebase or any SQL file.
- **No `trg_audit_*` trigger** on any table. The trigger inventory is
  `trg_calc_*`, `trg_validate_*`, `trg_update_flock_count`,
  `trg_recalc_customer_debt`, `trg_protect_inventory_quantity`,
  `trg_sync_tombstone_*`, `trg_populate_sync_changes`, `handle_new_user`,
  `prevent_self_privilege_escalation` — and nothing for audit.
- `DATABASE_SCHEMA_GUIDE.md:145` documents an `audit_trigger_function()` that
  **does not exist in any migration file**. *(doc-vs-code contradiction, logged)*


---

## ACC-009 — P1 — Duplicate payments on offline replay

**File:** `packages/data/lib/src/repositories/payment_repository_impl.dart:25-71`

`save()` has no idempotency key. The client is offline-first by design, so a
**queue replay after a partial success is a normal, expected event** — and if the
first attempt inserted the payment and then failed before recording `synced`,
the replay creates a second payment row.

Two identical $500 collections against a $1,000 invoice pass the per-row
`CHECK (amount_paid <= total_due)`, and `FinancialKpi` will report $1,000
collected against a $1,000 sale. The customer's real balance is unchanged, but
the cash figure is wrong.

`idempotency_log` exists in the schema and is unused by this path.

**Fix:** derive a deterministic operation key (e.g. `dispatch_id + date +
amount_paid + manager_id`, hashed) and add a `UNIQUE` constraint, or use
`idempotency_log` in the `sync_records_batch` path.

**Regression risk:** **Low** — additive constraint; clean existing duplicates first.

---

## ACC-010 — P1 — Credit notes and overpayment refunds are inexpressible

**File:** `supabase/migrations/UNIFIED_schema.sql:301,314`
**Constraint:** `amount_paid NUMERIC NOT NULL CHECK (amount_paid >= 0)` and
`CONSTRAINT check_amount CHECK (amount_paid <= total_due)`

A **negative payment** is impossible, so a credit note can never be recorded. The
data model cannot express "we owe the customer $50" or "return $200 of their
overpayment". Every real-world adjustment has to be made by editing a historical
row — which mutates history and fires the recalc trigger, producing a debt change
with no corresponding document.

**Fix:** add a `payment_type` column (`charge | credit`) and relax the CHECK to be
conditional on it, or add a separate `credit_notes` table.

**Regression risk:** **Medium** — touches the constraint the whole receivables
path depends on. Sequence it after ACC-001.

---

## ACC-011 — P2 — Silent failure handlers

Five files swallow exceptions with `catch (_) {}` or a misleading comment, on
paths that touch financial data:

| File | Line | Path |
|---|---|---|
| `revenue_repository_impl.dart` | 47, 53, 62, 76 | `save`, `update`, `delete`, `syncPendingRecords` |
| `expense_repository_impl.dart` | 54, 62, 73, 90 | same four |
| `save_dispatch_usecase.dart` | ~85 | `_openInvoice` (the ACC-006 case) |
| `opening_balance_repository_impl.dart` | 62, 68 | `save`, `delete` |
| `sync_repository_impl.dart` | — | reconciliation paths |

The offline-first design justifies *deferring* a write, but not *discarding the
error*. Nothing distinguishes "queued for later" from "failed permanently" from
the caller's perspective, and no user is ever told.

**Fix:** a small `Result` type or a `SyncOutcome` enum returned by these methods,
so the UI can distinguish "saved, will sync" from "could not save". This is what
turned ACC-006 from a visible error into a silent data-loss event.

**Regression risk:** **Low** — signature changes are contained to the UI layer.

---

## Critical Accounting Invariants — where each is actually enforced

| # | Invariant | Enforced? | Where |
|---|---|---|---|
| 1 | Debit == Credit | **N/A** | No double entry exists |
| 2 | Posted entry cannot be modified | **N/A** | No posting concept; all rows mutable |
| 3 | Posted entry cannot be deleted | **NO** | `mgr_all` allows manager DELETE on `payments` |
| 4 | Closed period cannot receive posting | **N/A** | No fiscal periods |
| 5 | No future-dated documents | **YES** | `CHECK (date <= CURRENT_DATE)` on 7 tables |
| 6 | Customer balance == subledger | **NO** | **ACC-001** — the trigger's own formula is wrong |
| 7 | Supplier balance == subledger | **N/A** | No supplier entity |
| 8 | Inventory valuation == Inventory GL | **N/A** | Neither exists |
| 9 | Cash ledger == Cash GL | **N/A** | Neither exists |
| 10 | Every posted invoice has a journal | **N/A** | No journals; the `payments`-row analogue is **ACC-006** |
| 11 | Every posted return is reversed | **N/A** | Returns do not exist |
| 12 | Every payment has a valid financial effect | **PARTIAL** | `CHECK (amount_paid <= total_due)` per-row; cumulative overpayment passes (ACC-009) |
| 13 | Every stock movement has a source/reference | **PARTIAL** | `inventory_transactions` exists but is not written atomically (ACC-002) and its remote path is broken (ACC-003) |
| 14 | Documents are numbered and unique | **NO** | No numbering of any kind |
| 15 | All writes are atomic | **NO** | **ACC-007** — one `db.transaction()` in the whole data layer |
| 16 | Operations are protected from duplicates | **PARTIAL** | UUIDs yes; business-level idempotency no (ACC-009) |
| 17 | Stock cannot go negative | **NO** | **ACC-005** — client-side check only |
| 18 | Every mutation is attributable | **NO** | **ACC-008** — `audit_log` never written |

**Score: 2 of 18 invariants are fully enforced, both of them operational rather
than financial.** Every financial invariant is either violated or undefined.

### Why it matters
Who reversed the journal, cancelled the invoice, changed the price, changed the
customer balance, changed the stock? **None are answerable**, and never will be,
because the table is permanently empty. Worse, managers are granted `SELECT` on
it, so a UI could display an "Audit Log" screen showing a permanently blank
result — a false promise.

### Current substitute (partial)
- `payments.manager_id` and `expenses.manager_id` record *who* — two tables only.
- `sync_changes` retains old/new payloads for replication — all synced tables, but
  it is a sync artefact rather than an intentional audit record, and it is subject
  to compaction (`compact_sync_changes`).

### Recommended fix
Add a generic `AFTER INSERT OR UPDATE OR DELETE` trigger per financial table
(`payments`, `expenses`, `revenue`, `inventory_items`, `inventory_transactions`,
`egg_dispatch`, `customers`) writing `(user_id, action, table_name, record_id,
old_values, new_values, farm_id, created_at)`. Every column already exists; only
the trigger is missing. `ARCHITECTURE_PLAN.md:820-842` specifies exactly this
function — **it was designed and never implemented.**

**Critical:** an audit table any `manager` can `DELETE` from is not an audit
table. Do not apply the `mgr_all` pattern to `audit_log`; grant `SELECT` only and
route retention through a `system_admin` RPC.

### Regression risk
**Low.** Additive. Volume is the only real concern — index
`(table_name, created_at DESC)` and add a retention job.

try {
  await payments.save(PaymentModel(... totalDue: 0 ...));
} catch (_) {
  // best-effort: لا يُفسد التخريج
}
```

**Why it matters:** every receivables, revenue, and profitability figure is
derived from `payments` — as migration `20260926000300` states explicitly. A
dispatch with no `payments` row is **invisible to all financial reporting**: it
contributes neither revenue nor an outstanding balance. It vanishes.

That migration is itself the evidence: the team discovered unpaid dispatches were
missing from reports and patched the *historical* data. **The bug that created
the gap was never fixed.**

**Real-world scenario:** a worker records 40 cartons on credit. `_openInvoice`
fails (transient DB error, or `paymentRepository` is null because the provider
was not wired in that build). The dispatch saves and displays. The customer owes
$600; the system shows $0 outstanding and the manager believes they paid in full.

**Fix:** (1) do not swallow the exception — roll the dispatch back, or mark it
`invoice_status = 'missing'` and show it on a manager "uninvoiced dispatches"
list until reconciled; (2) reuse the reconciliation query in `20260926000300` as
a scheduled check; (3) add a test asserting every dispatch with a customer has a
`payments` row.

**Regression risk:** **Low** — behaviour changes only in the failure path, which
is currently silent.

server does not.

Additionally, `updateItem()` sends `item.toJson()` minus `id` — but `quantity`
remains — so **any** attempt to edit an item's name, notes, or unit against the
server also throws.

### Why it matters
The trigger's intent is good (prevent direct balance edits) but it was written
without an escape hatch for the legitimate movement-driven update, and the client
was never updated to match. Result: silent, permanent local/remote divergence for
the entire inventory module.

### Current vs expected
- Current: online adjustments and item edits fail; the offline SQLite path
  succeeds (no such trigger). Two code paths, two truths.
- Expected: one `SECURITY DEFINER` RPC that validates the movement, applies the
  balance change, and enforces non-negativity — server-side and atomic.

### Recommended fix
Create `public.apply_stock_movement(p_item uuid, p_qty numeric, p_is_input bool,
p_note text, p_user uuid)` that inserts the movement, updates
`inventory_items.quantity` with a `CHECK (quantity >= 0)` guard, and is exempt
from `protect_inventory_quantity` (relax the trigger to permit a change when a
movement row exists in the same statement, or drop the trigger in favour of
revoking direct UPDATE on the `quantity` column via a column-level grant).

### Regression risk
**Low.** The local path is unaffected; only the remote adapter changes.

), 0) WHERE c.id = ...;
```

Note the backfill must run with `app.allow_debt_update` set, or it will be
silently reverted by the guard trigger.

### Regression risk
**Low.** The corrected formula matches what the SQLite DAO and the Dart
analytics already compute, so this *reduces* divergence rather than adding it.
The only visible effect is that customer balances drop — which is the point.
Add a regression test first (see TEST_COVERAGE_GAPS.md).

---
