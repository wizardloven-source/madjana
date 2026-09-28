# YASeen ERP — Test Coverage Gaps

**Companion to** `FULL_CODE_AUDIT.md`. READ-ONLY; no tests were run or modified.

---

## 1. Inventory

| Location | Files | ~Lines | Share |
|---|---|---|---|
| `packages/data/test` | 11 | ~3,800 | 82% |
| `packages/core/test` | 3 | ~330 | 7% |
| `apps/desktop/test` | **0** | 0 | 0% |
| `apps/mobile/test` | **0** | 0 | 0% |
| **Security tests** | **0** | 0 | — |
| **Accounting tests** | **0** | 0 | — |
| **Concurrency tests** | **0** | 0 | — |
| **Reconciliation tests** | **0** | 0 | — |

~4,100 lines across two packages. The two Flutter applications — which contain
**all** the business logic that actually runs (`dispatch_screen.dart` alone is
1,188 lines) — have **no test files at all**.

---

## 2. Classification of existing tests

| Class | File | Lines | Quality |
|---|---|---|---|
| Unit | `egg_calculator_test.dart` | 67 | Good — pure function, real assertions |
| Unit | `flock_model_test.dart` | 81 | Good |
| Regression | `mortality_regression_test.dart` | 182 | Good — named regressions |
| Database | `daos_occ_test.dart` | 405 | **Excellent** — exact payload assertions |
| Database | `daos_rest_test.dart` | 423 | **Excellent** |
| Database | `local_database_test.dart` | 217 | Good |
| Database | `device_id_regression_test.dart` | 50 | Good |
| Integration | `repositories_impl_test.dart` | 346 | Good |
| Integration | `repositories_impl_rest_test.dart` | 736 | Good |
| Contract | `remote_contract_test.dart` | 511 | Good — remote shape contract |
| Integration | `sync_repository_test.dart` | 569 | **Excellent** — strongest file in the repo |
| Integration | `backup_service_test.dart` | 114 | Good — checksum, corruption, pruning |

### What is genuinely well tested
- **Optimistic concurrency and sync queueing.** `previous_version` values, exact
  payload contents, sync-status transitions, insert-vs-update routing. These tests
  assert on *real database state*, opening an in-memory sqflite database and
  inspecting it. That is the right way to test a DAO.
- **Sync engine.** Conflicts, tombstones, batching, reconciliation, live-ID
  handling — 569 lines.
- **Repository offline/online behaviour**, including remote-wins/local-wins merge
  precedence.
- **Backup integrity**, including rejection of a corrupted archive.
- **Test doubles are honest.** `fake_supabase_api.dart` (284 lines) and
  `db_harness.dart` (24 lines) are small and structural — no `sys.path` hacks, no
  hardcoded absolute paths, and no faked accounting logic, because there is no

---

## 3. The pattern — and it is the finding

> **Every subsystem that has tests is `sync/infra`.
> Every subsystem with no tests is `money/business`.**

| Subsystem | Tested? | Defects found? |
|---|---|---|
| Sync queue / OCC | ✅ 1,100+ lines | none found |
| Repository impls | ✅ 1,082 lines | minor only |
| Backup | ✅ 114 lines | none found |
| Egg calculator | ✅ 67 lines | none found |
| **Receivables (ACC-001)** | ❌ **0** | **P0, shipped** |
| **Atomicity (ACC-002, 007)** | ❌ **0** | **P0, shipped** |
| **Inventory write path (ACC-003)** | ❌ **0** | **P0, shipped** |
| **Negative stock (ACC-005)** | ❌ **0** | **P0, shipped** |
| **Dispatch→invoice (ACC-006)** | ❌ **0** | **P0, shipped** |
| **Idempotency (ACC-009)** | ❌ **0** | P1, shipped |
| **Audit trail (ACC-008)** | ❌ **0** | P1, shipped |
| **RLS enforcement (SEC-002)** | ❌ **0** | P1, unverified |

**Every P0 in this audit is in an area with zero test coverage, and no defect was
found in any area that has tests.** Not a coincidence — the clearest possible
statement of where the risk sits.

### Why the tests pass while the business logic is wrong
This is the important mechanism. `PaymentDao` tests assert:

> `test('getTotalCollected يحسب الإجمالي الصحيح', ...)` — and `getTotalOutstanding`
> is covered by a test that passes.

The **SQLite** implementation of outstanding balance is correct, so the test
passes. **But the production value comes from the Postgres trigger** — a
different implementation, in a different language, that no test touches. The
suite therefore gives strong assurance about a code path that is not the
authoritative one.

**A test suite that covers a shadow implementation of your most important
invariant is worse than none**, because it produces confidence.

---

## 4. The five tests that would have caught the P0s

In priority order. Together roughly 400 lines.

### T1 — Multi-payment receivables (catches ACC-001)
Postgres integration test, two payments against one dispatch:
```sql
-- invoice 1000, payments 300 then 200
INSERT INTO payments(dispatch_id, customer_id, total_due, amount_paid, ...)
  VALUES (d, c, 1000, 300, ...);
INSERT INTO payments(dispatch_id, customer_id, total_due, amount_paid, ...)
  VALUES (d, c, 1000, 200, ...);
-- assert: SELECT total_debt FROM customers WHERE id = c;  -- must be 500
```
**The single most valuable test in the project.** ~30 lines, and it would have
blocked the most severe defect in the codebase. It fails today.

### T2 — Transactional rollback on injected failure (catches ACC-002, ACC-007)
Assert that if the second write in a multi-write repository method throws, the
first is rolled back. No mocking needed: use a sqflite database, a DAO whose
second statement violates a constraint, and assert the first row is absent. Today
there is no transaction, so the test shows a partial state — which is the bug.

### T3 — Worker is blocked from financials (catches SEC-002)
Authenticate as `role = 'worker'` and assert that `SELECT` and `INSERT` on
`payments`, `expenses`, `revenue`, and `customers` are all rejected, while

---

## 5. Testing that should exist but is currently absent

| Area | Test needed | Catches |
|---|---|---|
| Reconciliation | per-customer `MAX(total_due) − SUM(amount_paid)` == `customers.total_debt`, as a scheduled assertion | ACC-001 permanently |
| Reconciliation | dispatch total == priced line total | invoice mispricing |
| Concurrency | two parallel `adjustStock` calls → no lost update | lost-update class |
| Idempotency | replay the same sync-queue entry twice → one row | ACC-009 |
| Analytics | `FinancialKpi` with partial payments across a date boundary | period-boundary errors |
| Analytics | `CostPerEgg` with unpriced feed → asserts `unpricedShipments > 0` is surfaced | silent cost understatement |
| Presentation | `_recordPayment` price-change flow (`dispatch_screen.dart:123-247`, 124 lines of branching) | the most complex UI path in the app |
| E2E | record eggs → dispatch → price → partial pay → check balance | everything together |

---

## 6. Test quality in what exists

**No fake repositories masking business logic.** `fake_supabase_api.dart`
implements the remote interface structurally; it does not reimplement any
calculation. Correct approach — preserve it.

**No hardcoded paths or environment dependencies.** Tests use in-memory sqflite
via `db_harness.dart` and need no live Supabase instance, so `flutter test` runs
anywhere.

**One structural weakness:** `repositories_impl_rest_test.dart` and
`remote_contract_test.dart` test the *client's* understanding of the remote
schema. Nothing verifies that the Postgres triggers behave as the client assumes.
That assumption gap is exactly where ACC-001 and ACC-003 live — two places where
the Dart code is correct in isolation and the SQL contradicts it.

---

## 7. Recommendation

1. **Write T1, T2, T3 before fixing anything.** ~120 lines. Fixing ACC-001
   without T1 means the same class of bug returns the next time someone edits
   that trigger.
2. **Add the standing reconciliation query** (§5, first row) to CI or a nightly
   job. One SQL statement; makes silent receivables corruption impossible.
3. **Treat "no test touches the Postgres triggers" as the root cause.** The
   database holds this system's most important business rules and the harness
   cannot currently reach them. Standing up a lightweight Postgres integration
   harness (Testcontainers, or a CI service container) is the single
   highest-leverage investment available to this project.
4. **Do not chase a coverage percentage.** The number would mislead: 82% of tests
   already sit in `sync`, and coverage there is not the risk. Measure instead —
   *is every business invariant enforced somewhere a test can see?* Today the
   answer is **2 of 18** (`ACCOUNTING_INTEGRITY_AUDIT.md`).

`egg_production` succeeds. ~40 lines — the test that would let anyone state with
confidence that the authorization model holds.

### T4 — Inventory cannot go negative (catches ACC-005)
Two adjustments against a balance of 10, each removing 8. Assert the second is
rejected and the final quantity is 2, not -6. Today the client-side check passes
both, because each device sees a stale local balance.

### T5 — Every dispatch has an invoice (catches ACC-006)
```sql
SELECT count(*) FROM egg_dispatch d
WHERE d.deleted_at IS NULL AND d.customer_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM payments p WHERE p.dispatch_id = d.id);
-- must be 0
```
The same query migration `20260926000300` used to backfill. Run as a standing
invariant check and the ACC-006 class cannot recur silently.

  accounting logic to fake.

**This is real testing, not test theatre.** The infrastructure-quality work in
this repo is genuinely verified.
