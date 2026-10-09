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

---\n\n## 5. Stock adjustments

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
| A flock cannot be deleted while money points at it | `expenses.flock_id` FK `ON DELETE RESTRICT` |
| An expense cannot name a flock of another farm | `trg_validate_flock_expenses` → `validate_flock_farm()` |
| A non-existent `farm_id` is refused | `expenses_farm_id_fkey` |
| Scoped cost queries stay fast | `idx_expenses_farm_flock`, `idx_expenses_flock_direct` |

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

---

## Change log

| Date | Change |
|---|---|
| 2026-09-27 | Document created (M1). `expenses.flock_id` defined. |
| 2026-10-03 | M2: `stock_adjustments` gets `flock_id`, `unit_price`, `currency`. `farm_id` FK fixed to RESTRICT. |
| 2026-10-03 | M3: `medications` gets `cost`, `currency`, `inventory_item_id`. |
| 2026-10-09 | M12: `FlockCostCalculator` implements §6 in Dart; `FlockPerformance.estimatedCost` replaced by `costBreakdown`. No schema change. |


