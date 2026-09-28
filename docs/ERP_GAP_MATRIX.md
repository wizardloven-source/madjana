# YASeen ERP — ERP Gap Matrix

**Companion to** `FULL_CODE_AUDIT.md`. READ-ONLY.

**Framing:** this matrix compares YASeen ERP against a **commercial accounting
package** (the brief's benchmark), *and* against what it actually is — an
offline-first poultry farm operations system. The second comparison determines
whether it is ready to ship.

**Scale:** YES = complete and evidenced in code · PARTIAL = real implementation,
materially incomplete · NO = absent · UNKNOWN = not provable from code.

---

## 1. Headline

| | |
|---|---|
| Accounting ERP completeness | **NO** — the subsystem does not exist |
| Farm-operations completeness | **PARTIAL** — strong core, three P0 blockers |
| Ready to ship as a farm app? | **Not until ACC-001, ACC-002/003, ACC-004 close** |

---

## 2. Against a commercial accounting package

| # | Capability | Status | Evidence |
|---|---|---|---|
| 1 | Chart of Accounts | **NO** | no `accounts` table; 0 references |
| 2 | General Ledger | **NO** | no `journal_lines`; 0 references |
| 3 | Journal Entries | **NO** | 0 references to `journal_entry` |
| 4 | Double-entry enforcement | **NO** | no representation in the schema |
| 5 | Posting engine (draft→posted) | **NO** | all records live and mutable |
| 6 | Reversal / credit note | **NO** | no reversal path |
| 7 | Trial Balance | **NO** | — |
| 8 | Balance Sheet | **NO** | — |
| 9 | Income Statement | **NO** | — |
| 10 | Cash Flow Statement | **NO** | — |
| 11 | Fiscal periods / year-end close | **NO** | 0 references to `fiscal`/`period` |
| 12 | Document numbering & sequences | **NO** | UUIDs only |
| 13 | Audit trail | **NO** | `audit_log` never written |
| 14 | Approval workflow | **NO** | no approval states |
| 15 | Accounts Payable | **NO** | no `suppliers` table |
| 16 | Purchase Orders / GRN | **NO** | free-text `feed_received` only |
| 17 | Inventory valuation (FIFO/AVG) | **NO** | no `unit_cost` anywhere |
| 18 | Cost layers | **NO** | no cost field on any movement |
| 19 | Warehouses / locations | **NO** | single implicit location |
| 20 | Batch / lot / serial / expiry | **NO** | — |
| 21 | Fixed assets & depreciation | **NO** | 0 references to `depreciation` |
| 22 | Cashboxes / bank / treasury | **NO** | `payment_method` is a label, not an account |
| 23 | Tax (VAT) | **NO** | no rates, no tax accounts |
| 24 | Customer statement | **NO** | — |
| 25 | Supplier statement | **NO** | — |
| 26 | AR aging | **NO** | flat `outstanding > 1000` threshold |
| 27 | AP aging | **NO** | — |
| 28 | Bank reconciliation | **NO** | — |
| 29 | Subledger ↔ control reconciliation | **NO** | no control accounts exist |
| 30 | FX revaluation | **NO** | rate stored, never used |
| 31 | Historical FX rate table | **NO** | rate lives on the document row |
| 32 | Rounding policy | **PARTIAL** | `NUMERIC(16,8)` chosen ad hoc to fix a rounding bug |
| 33 | Budgets | **NO** | — |
| 34 | Cost centres | **NO** | — |
| 35 | Manufacturing | **NO** | — |
| 36 | CRM | **NO** | `customers` is a contact list only |
| 37 | Segregation of duties | **PARTIAL** | 2 roles; no cashier/accountant split |

---

## 3. Against what it actually is — a farm-operations system

| # | Capability | Status | Notes |
|---|---|---|---|
| 1 | Flock lifecycle | **YES** | start/end, `current_count` by trigger |
| 2 | Egg production recording | **YES** | `calc_total_eggs` trigger |
| 3 | Mortality recording | **YES** | trigger decrements `flocks.current_count` |
| 4 | Feed receipt (quantity) | **YES** | unit conversion DB-enforced |
| 5 | Feed consumption | **YES** | `bags`/`kg` modes, 24 kg/bag enforced |
| 6 | Feed days-of-stock estimate | **YES** | `FarmAnalytics.feedDaysLeft` |
| 7 | Egg dispatch (cartons/trays) | **YES** | `calc_dispatch_total` trigger |
| 8 | Egg stock check before dispatch | **PARTIAL** | computed in a widget, not enforced in DB |
| 9 | Withdrawal-period safety block | **YES** | good domain feature, applied at dispatch |
| 10 | Customer master | **PARTIAL** | global-customer model well done; balance wrong (ACC-001) |
| 11 | Invoice + collection recording | **PARTIAL** | works, not atomic, no idempotency |
| 12 | Customer outstanding balance | **NO** | **ACC-001** — authoritative formula is wrong |
| 13 | Customer statement | **NO** | — |
| 14 | AR aging | **NO** | — |
| 15 | Partial payments | **PARTIAL** | UI supports installments; server math does not |
| 16 | Sales returns | **NO** | — |
| 17 | Expenses | **PARTIAL** | 9 fixed categories; no AP, no supplier link |
| 18 | Revenue (other) | **PARTIAL** | manual; `eggSales` category not auto-fed |
| 19 | Inventory quantity | **NO** | write path broken online (ACC-003) |
| 20 | Inventory valuation | **NO** | — |
| 21 | Multi-farm support | **YES** | `user_farms` + `set_active_farm`; well designed |
| 22 | System admin console | **YES** | 10 `admin_*` RPCs, all guarded |
| 23 | Offline-first operation | **YES** | the standout feature |
| 24 | Sync conflict resolution | **YES** | versioned, tombstoned, well tested |
| 25 | Backup & restore | **YES** | checksummed, corruption-detecting, tested |
| 26 | Production KPIs | **YES** | pure functions, correct |
| 27 | Flock profitability | **PARTIAL** | `estimatedMargin` — a cash proxy, not profit |
| 28 | Cost per egg | **PARTIAL** | feed + pro-rated expenses; excludes labor, medicine, depreciation |
| 29 | Multi-currency | **PARTIAL** | USD/LBP display; no FX accounting |
| 30 | Audit trail | **NO** | ACC-008 |
| 31 | Role separation | **PARTIAL** | worker/manager only |
| 32 | Document numbering | **NO** | — |

**Score: 10 YES, 12 PARTIAL, 10 NO.**

**Read this carefully:** the 10 "NO"s are not mostly missing *farm* features —
they are the missing *money* features. Flocks, production, feed, dispatch,
offline, sync, backup, and multi-farm are all solid. Everything that turns
operational records into **financial truth** is missing or broken.

---

## 4. The three highest-value additions

---

## 5. What should explicitly NOT be built yet

- **Manufacturing** — no demand signal, and it requires costing that does not exist.
- **CRM** — `customers` is a contact list; a CRM implies a sales pipeline this
  business does not run.
- **Multi-warehouse** — single-site operations; a premature abstraction.
- **Fixed assets** — worth it eventually, but only after a balance sheet exists
  to put them on.

---

## 6. Documentation vs code — contradictions logged

Per the brief, contradictions are recorded rather than resolved.

| Document | Claim | Reality |
|---|---|---|
| `DATABASE_SCHEMA_GUIDE.md:145` | `audit_trigger_function()` records changes to `audit_log` automatically | **No such function or trigger exists in any migration** |
| `DATABASE_SCHEMA_GUIDE.md:170` | `audit_log_manager` — "المدير فقط يرى سجل التدقيق" | Table is permanently empty; there is nothing to see |
| `ARCHITECTURE_PLAN.md:820-842` | Specifies adding `farm_id`, `device_id`, `ip_address`, `reason` to `audit_log` and fixing the audit trigger | **Designed, never implemented** |
| `FEATURE_GAP_AUDIT.md:335` | "الربحية ✅ via phase1_analytics — PARTIAL" | The metric is `collected − expenses`; no COGS. The PARTIAL rating is right, but the ✅ overstates it |
| `FEATURE_GAP_AUDIT.md:344` | "`CostPerEgg` and `FlockProfitability` … حسابات تقريبية" | **Accurate.** Best documentation-to-code alignment in the repo |
| `FEATURE_GAP_AUDIT.md:348` | `profit_loss_report` and `cash_flow_report` do not exist | **Accurate** |
| `08_PRODUCTION_BLOCKERS.md:145` | `currencyProvider` always returns `$` (P3-06) | **Still present** — `AppCurrency` is display-only, and `Formatters.formatCurrency` hardcodes `symbol = '\$'` as a default argument |
| `docs/production/PHASE_1_FEATURE_INVENTORY.md:6` | "Flock Accounting Screen" (`flock_accounting_screen.dart`) | **Misleading name.** The file computes operational and estimated-margin KPIs; no flock cost exists anywhere |

**Overall pattern:** `docs/production_audit/` is honest and largely matches the
code; the higher-level planning documents (`ARCHITECTURE_PLAN.md`, the PRD)
describe an *intended* system rather than the built one. In every case checked,
the code matches the audit documents rather than the planning documents.


If only three things were added, these are they — in order:

### 1. A cash account and a real cash total
Today: impossible to answer "how much money is in the safe?"
Requires: a `cash_accounts` table, a `cash_movements` table, and one
`opening + collections − expenses + transfers` query. The smallest change that
converts the app from "records what happened" to "knows where it stands".

### 2. Inventory valuation and stock linkage
Today: feed received does not enter stock; eggs dispatched do not leave stock;
`inventory_items` has no cost.
Requires: `unit_cost` on `feed_received` (already present, nullable) and on
`inventory_transactions`; a valuation method; a dispatch→stock link. The single
largest source of unrealised profit in the current model.

### 3. Customer statement and aging
Today: the balance is wrong (ACC-001) and there is no aging.
Requires: the ACC-001 fix, then `due_date` buckets. The schema already stores
`payments.due_date` — the field exists and is unused. Cheap, and it is what a
farm owner actually checks weekly.

| 38 | Budget approval | **NO** | — |

**Score: 0 of 38.**
