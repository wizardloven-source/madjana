# ACCOUNTING_RULES — Madjana

The rules that decide what costs what, and who a number belongs to.
Ambiguity here is what produced the original `feedKg x pricePerEgg` bug, so
every rule below is stated as a decision with its reason, and each one has
a test that fails if it is broken.

---

## 1. The one rule that matters most

> **A cost belongs to a flock only if that cost names that flock.**

| `flock_id` | Meaning | Counts in flock P&L? |
|---|---|---|
| **SET** | direct cost of that flock | **yes** |
| **NULL** | farm-level cost | **never** |

There is no third option and no automatic allocation. Nothing is
proportioned across flocks, ever. If money cannot be attributed to one
flock with confidence, it stays at the farm.

### Why NULL is meaningful and not "missing data"

`NULL` is a deliberate classification, not an unfinished field. Salaries are
the clearest case: a farmhand is paid by the farm, for the farm, whether or
not one flock happens to be busier this month. Writing a flock_id on a
salary would be a fiction, and fiction in a P&L becomes a number somebody
acts on.

---

## 2. Expense categories

| Category | `flock_id` | Notes |
|---|---|---|
| `labor` (salaries) | **always NULL** | paid by the farm, not by a bird |
| `electricity` | **SET** | entered manually against the flock it serves |
| `feed` | **SET** | see §3 — feed has its own table |
| `medicine` | **SET** | see §4 |
| `maintenance`, `transport`, `water`, `carton`, `other` | either | manager's judgement at entry |

---

## 3. Feed is not an expense row

Feed arrives in `feed_received` and leaves in `feed_consumption`. Its cost
is derived, never re-entered:

```
feed cost for flock X = SUM(quantity_kg * price_per_kg)   -- feed_received
```

An `expenses` row with `category = 'feed'` would **double-count** the same
purchase. The app must not create one, and the cost query must not read
`expenses` for feed.

---

## 4. Medicines (added in M3)

Priority order, first match wins:

1. `inventory_item_id` set → cost of the units actually drawn down,
   priced by the stock movement that consumed them
   (`stock_adjustments.unit_price` × quantity). `inventory_items`
   carries **no** price column of its own — there is no `unit_cost` to
   multiply — so when no movement price exists the row falls through to
   rule 2. (Valuation is still an open gap: `docs/ERP_GAP_MATRIX.md` §17.)
2. otherwise `cost` (entered by the manager at treatment time)
3. otherwise **0, with a visible warning to the manager**

A silent 0 is how money disappears from a report. If the cost is unknown,
the interface must say so.

### Constraints enforced by the database

| Column | Rule |
|---|---|
| `cost` | NULL allowed; if set, must be ≥ 0 |
| `currency` | NOT NULL, default `'dollar'`, CHECK (`'dollar'` \| `'lira'`) |
| `inventory_item_id` | NULL allowed; FK → `inventory_items(id)` ON DELETE SET NULL |

The currency convention matches `expenses` and `payments`: dollar/lira only.
`SAR`, `USD`, `EUR` and any other code are rejected at insert time.

---

## 5. Stock adjustments

```
stock cost for flock X = SUM(delta_qty * unit_price)   -- stock_adjustments
```

Requires `unit_price`. A quantity with no price is not a cost and must not
be summed as one.

---

## 6. The cost formula

```
flockCost(X) =
      SUM(expenses.amount              WHERE flock_id = X)
    + SUM(feed_received.quantity_kg
          * feed_received.price_per_kg WHERE flock_id = X)
    + SUM(medications.cost             WHERE flock_id = X)
    + SUM(stock_adjustments.delta_qty
          * stock_adjustments.unit_price WHERE flock_id = X)
```

Farm overhead — salaries and anything else with `flock_id IS NULL` — is
**not** in this formula. If a farm wants an overhead-loaded figure, that is
a separate, explicitly labelled number, never a silent addition here.

### `FlockCostCalculator` (Dart — M12)

`packages/core/lib/src/services/flock_cost_calculator.dart` implements the
formula above in Dart. The mirror decisions it encodes:

| Rule | Implementation |
|---|---|
| flock gets only what names it | all four inputs filtered by `flockId`; the caller may pass farm-wide lists |
| farm-level money stays out | `expenses`/`feed`/`medications`/adjustments with `flock_id IS NULL` skipped |
| unpriced ≠ free | every unpriced row (feed without `price_per_kg`, adjustment without `unit_price`, medication that resolves to nothing) is counted in `unpriced*` and summed as `0` — the interface must surface the warning, never a silent zero (§4 non-negotiable) |
| medicine priority (§4) | inventory-linked med priced by its stock movement (`inventoryUnitPrices` map) wins; no movement price → falls back to `cost`; none → `0` + warning |
| signed adjustments | `delta_qty × unit_price` is summed signed (a write-off is a negative term) |
| never negative | `totalCost` is clamped at `0`; the per-source signed values stay visible in the breakdown |
| money precision | each component and `totalCost` round to 4 decimals (`NUMERIC(19,4)`/`(12,4)`) |

The medication quantity for an inventory-linked row is the draw-down itself
(one unit per record): `quantity` is not tracked per medication, so the
movement price prices the unit drawn, not a multiplied dose.

---

## 7. Revenue

Revenue is counted once per invoice, not once per payment. A dispatch sold
on 7-day terms generates several `payments` rows against the same invoice;
summing `amount_paid` would multiply the revenue. Take the invoice total
once:

```sql
-- one row per dispatch, the highest total_due recorded for it
SELECT dispatch_id, max(total_due) FROM payments
 WHERE dispatch_id IS NOT NULL GROUP BY dispatch_id;
```

Implemented in `phase1_analytics.dart` (`FlockPerformance.calculate`,
"invoiceByDispatch"). Do not reintroduce a naive sum.

### Flock attribution (added in M1b)

Revenue follows the **same one rule** as costs (§1):

| `flock_id` | Meaning | Counts in flock P&L? |
|---|---|---|
| **SET** | direct revenue of that flock (egg sales, live-chicken sales) | **yes** |
| **NULL** | farm-level revenue (sold building, equipment, misc) | **never** |

The column was added with no default, so every pre-existing revenue row is
farm-level. That is deliberate (see §10): attributing historical money to a
flock would be a guess. `revenue.flock_id` mirrors `expenses.flock_id`
exactly — same nullable uuid FK, same `ON DELETE RESTRICT`, same
`validate_flock_farm()` guard.

---

## 8. Currency

All money is recorded in **US dollars**. Syrian lira is a *display and
input* convenience, never a stored unit.

- `currency` records how the figure was **entered** (`dollar` | `lira`)
- `exchange_rate` records the rate used **at entry time**
- the stored `amount` is already the dollar equivalent

A lira figure typed today must not be re-converted later with a different
rate. Re-converting a stored amount is the single most common way to
corrupt an accounts ledger, and it is why the rate is frozen into the row.

**Open question for the owner:** the reference rate's origin and refresh
policy are not yet defined (manual entry vs a fetched rate). Until that is
settled, the rate is entered by the manager and the row remembers it.

---

## 9. Integrity guarantees enforced by the database

| Guarantee | Mechanism |
|---|---|
| A flock cannot be deleted while money points at it | `expenses.flock_id` **and** `revenue.flock_id` FK `ON DELETE RESTRICT` |
| An expense cannot name a flock of another farm | `trg_validate_flock_expenses` → `validate_flock_farm()` |
| A revenue row cannot name a flock of another farm | `trg_validate_flock_revenue` → `validate_flock_farm()` |
| A non-existent `farm_id` is refused | `expenses_farm_id_fkey` / `revenue_farm_id_fkey` |
| Scoped cost/revenue queries stay fast | `idx_expenses_farm_flock`, `idx_expenses_flock_direct`, `idx_revenue_farm_flock`, `idx_revenue_flock_direct` |

The `flock_id` FK is `RESTRICT`, not `SET NULL`. Silently blanking the
reference would turn a refused delete into a silent orphaning of the
money. (`flock_movements.worker_id` is `SET NULL` for the opposite reason:
a person's attribution is not a financial entity.)

---

## 10. Historical data

`expenses.flock_id` was added with no default, so every pre-existing expense
is a farm-level cost. That is deliberate: distributing historical money
across flocks would be a guess, and a wrong guess in an accounting system
is worse than an honest blank.

Backfilling is allowed **only** with a documented, reversible script, and
only for rows where the true flock is known from another source (e.g. a
feed invoice that names a flock).

---

## 11. Tests that enforce this file

| Rule | Test |
|---|---|
| direct vs farm-level split | `supabase/tests/p0_expenses_flock_test.sql` §6 |
| salary never enters a flock | same, §6 |
| cross-farm linking refused | same, §3 |
| delete-with-expenses refused | same, §5 |
| one invoice counted once | `packages/core/test/profitability_revenue_merge_test.dart` |
| four-source flock cost, NULL excluded, never negative, 4-dp rounding | `packages/core/test/flock_cost_calculator_test.dart` |
| partner profit split, four share models, error rails (§12) | `supabase/tests/p0_partner_reports_test.sql` (**4ad**) |
| partner profit basis includes collected payments (§12, M29) | `supabase/tests/p0_partner_net_profit_fix_test.sql` (**4af**) |
| partner profit sums raw USD across mixed `currency` rows (§12.2, M29-v2) | `supabase/tests/p0_partner_net_profit_fix_v2_test.sql` (**4ag**) |
| partner lifecycle + withdrawal ladder (§12.3) | `supabase/tests/p0_partner_e2e_test.sql` (**4ac**) |
| partner cross-farm isolation (§12) | `supabase/tests/p0_partner_isolation_test.sql` (**4ae**) |

---

## 12. Partner profit & distributions (W6)

The partnership layer (**W6**) adds a profit-sharing ledger on top of the
rules above. It **does not change** §1 — a partner's money is still
classified by `flock_id` like any other figure; the distribution merely
divides the farm's net profit after the fact.

### 12.1 The distribution is a ledger, not a re-entry

Profit is never typed in twice. The books (`revenue` / `expenses`, §1 and §7)
are summarised into a `profit_distributions` **header** and one
`profit_distribution_details` **line per partner**. Both equations are
enforced by CHECKs, so a header that does not add up cannot be stored by
anyone:

* `net_profit = total_revenue − total_expenses`
* `distributable_profit = net_profit − reserve_amount`
* `net_amount = profit_share + salary_total − deductions`

A reserve is withheld **before** sharing: only `distributable_profit` is
split, never `net_profit`.

### 12.2 How a partner's share is computed

`calculate_profit_distribution(p_farm_id, start, end[, flock])` previews the
split (read-only); `partner_net_profit(p_partner_id, start, end[, flock])`
returns one partner's figure. The split depends on `share_model`:

| `share_model` | profit share |
|---|---|
| `percentage` | `distributable_profit × percentage / 100` |
| `shares` | `distributable_profit × shares / Σshares` over active shares partners |
| `salary` | `0` — the partner takes the fixed `salary_amount` instead |
| `mixed` | the fixed salary **plus** the `percentage` (if set), else the shares-normalised amount |

The **revenue basis** is cash plus other income (M29):

```
net = ( SUM(payments.amount_paid) + SUM(revenue.amount) ) − SUM(expenses.amount)
```

**Currency is metadata.** `amount` is **always** US dollars; `currency` — how
the money was handed over (`dollar` | `lira`) — is metadata, never a unit to
convert from, and `exchange_rate` is a frozen entry-time rate that neither
function reads (M29-v2). Because every amount already shares one unit, a row
recorded in `lira` next to a row recorded in `dollar` is **not** a conflict:
both functions sum the raw `amount`s and never raise `MIXED_CURRENCY`. E.g. an
expense of `34.22` (already USD) with `currency = 'lira'` and
`exchange_rate = 13150` adds exactly `34.22` to the total — no conversion.

When `p_flock_id` is set a payment counts only if its dispatch points at that
flock (`payments.dispatch_id → egg_dispatch.flock_id`); a direct payment with
no dispatch is farm-level and is excluded from a flock-scoped figure.

When `p_flock_id` is **NULL** the calculation covers the whole farm (and, for
`partner_net_profit`, which has no farm argument, **all** farms). Active
percentage partners summing above 100 raise `INVALID_PERCENTAGES`.

### 12.3 The withdrawal path

A withdrawal moves a partner's **already-allocated** share out of the
business. It never creates a `revenue` or `expenses` row, and it never names
a flock — §1 is untouched. The ladder is:

```
pending ──▶ approved ──▶ paid        (or pending/approved ──▶ cancelled; pending ──▶ rejected)
```

`pending` + `approved` are still owed and count as **pending** in
`partner_summary` / `partner_pending_withdrawal`; `paid` is money already
out. A withdrawal tied to a `distribution_id` must point at a distribution
of the same farm (`WITHDRAWAL_DISTRIBUTION_MISMATCH` otherwise).

### 12.4 Worked example

Farm A, October: `total_revenue` 1800, `total_expenses` 500 → `net_profit`
1300; `reserve_amount` 300 → `distributable_profit` 1000.

| partner | model | input | profit_share | salary_total | net_amount |
|---|---|---|---|---|---|
| A | `percentage` | 25 | 250.00 | 0 | 250.00 |
| B | `percentage` | 40 | 400.00 | 0 | 400.00 |
| C | `salary` | 120 `monthly` | 0 | 120.00 | 120.00 |
| D | `mixed` | 10% **+** 50 | 100.00 | 50.00 | 150.00 |

Σ `profit_share` = 750 ≤ 1000 — the difference stays undistributed (and a
`shares` partner would instead take `1000 × shares / Σshares`). Partner A then
requests 100: `pending` (partner-inserted) → `approved` (manager) → `paid`
when the cash leaves, at which point `paid_at` is stamped.

---

## Change log

| Date | Change |
|---|---|
| 2026-09-27 | Document created (M1). `expenses.flock_id` defined. |
| 2026-10-03 | M2: `stock_adjustments` gets `flock_id`, `unit_price`, `currency`. `farm_id` FK fixed to RESTRICT. |
| 2026-10-03 | M3: `medications` gets `cost`, `currency`, `inventory_item_id`. |
| 2026-10-09 | M12: `FlockCostCalculator` implements §6 in Dart; `FlockPerformance.estimatedCost` replaced by `costBreakdown`. No schema change. |
| 2026-10-12 | M1b: `revenue.flock_id` added (nullable uuid, `ON DELETE RESTRICT`, guarded by `validate_flock_farm()`); §7 gains the direct-vs-farm revenue rule; §9 table extended to revenue. |
| 2026-10-13 | W6 (M21–M28): §12 added — partner profit rules (`partner_net_profit`, `calculate_profit_distribution`), the four share models, the withdrawal ladder and a worked numeric example. Tests: 4ac/4ad/4ae. |
| 2026-10-13 | M29: §12.2 revenue basis corrected to `payments.amount_paid + revenue.amount` (M24 counted `revenue` only, dropping all collected cash). Currency stays metadata; `exchange_rate` is not read. Test: 4af. |
| 2026-10-14 | M29-v2: §12.2 — removed `MIXED_CURRENCY`; the functions sum raw USD amounts and treat `currency` purely as metadata (a `lira` row beside a `dollar` row is not a conflict). Test: 4ag. |


