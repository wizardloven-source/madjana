# 04 — Test Coverage Audit

> Read-only audit on 2026-09-11. All test files read and analyzed.

## 1. Test Results

```
packages/core:  9 tests — ALL PASSED
packages/data: 160 tests — ALL PASSED
TOTAL:         169 tests — ALL PASSED
```

## 2. Test Inventory

### packages/core/test/

| File | Tests | What It Tests |
|------|-------|---------------|
| `egg_calculator_test.dart` | 9 | `calculateTotal`, `normalize`, `kgToBags`, `tonsToKg`, `formatDate`, `formatNumber`, `formatWeight` |

**Coverage:** Pure calculation utils only. No model tests, no use-case tests, no repository interface tests.

### packages/data/test/

| File | Tests | What It Tests |
|------|-------|---------------|
| `daos_occ_test.dart` | 36 | OCC insert/update/delete for all 10 operational DAOs — sync queue entries, payload cleanliness, previous_version |
| `daos_rest_test.dart` | 48 | CustomerDao, UserDao, SessionDao, SettingsDao, NotesDao, RemindersDao, OpeningBalanceDao, DispatchRequestDao, SyncQueueDao CRUD |
| `local_database_test.dart` | 16 | Schema validation (_onCreate v19), upgrade self-healing, enqueueChange, clearAll, integrity check, backup |
| `remote_contract_test.dart` | 28 | Contract tests for all 16 remote datasources — correct API calls, filters, operations |
| `repositories_impl_rest_test.dart` | 54 | All repository impls: offline-first (online→cache→offline fallback), sync, CRUD, error handling |
| `repositories_impl_test.dart` | 32 | Core repos: EggProduction, Payment, Flock, Conflict — local+remote round-trip |
| `sync_repository_test.dart` | 10 | Sync engine: uploadBatch (success/conflict/error/network), pullAndMerge (merge/watermark/resync), syncNow full cycle |

### Test Support

| File | Purpose |
|------|---------|
| `support/db_harness.dart` | Temp SQLite database creation via FFI |
| `support/fake_supabase_api.dart` | In-memory Supabase API fake with call recording, failure injection, data seeding |

### supabase/tests/

| File | Tests | What It Tests |
|------|-------|---------------|
| `p0_isolation_and_sync_test.sql` | 4 scenarios | Farm isolation (RLS), worker financial access (RLS+RPC), idempotency, OCC conflict |

## 3. What IS Tested

| Behavior | Evidence | Verdict |
|----------|----------|---------|
| Offline-first read pattern | `repositories_impl_rest_test.dart` — systematic online→cache→offline for every repo | **PASS** |
| OCC queue generation | `daos_occ_test.dart` — every DAO enqueue test | **PASS** |
| Sync upload/pull/retry | `sync_repository_test.dart` — network failure, conflict, backoff | **PASS** |
| Database schema integrity | `local_database_test.dart` — all tables, columns, indexes exist | **PASS** |
| Remote datasource contracts | `remote_contract_test.dart` — correct API calls for all datasources | **PASS** |
| Conflict record CRUD | `repositories_impl_test.dart` — add/get/resolve/ignore | **PASS** |
| Farm isolation (SQL) | `p0_isolation_and_sync_test.sql` P0-1 | **PASS** |
| Worker financial access (SQL) | `p0_isolation_and_sync_test.sql` P0-2 | **PASS** |
| Idempotency (SQL) | `p0_isolation_and_sync_test.sql` P0-3 | **PASS** |
| OCC conflict detection (SQL) | `p0_isolation_and_sync_test.sql` P0-4 | **PASS** |

## 4. What is NOT Tested

| Gap | Severity | Evidence |
|-----|----------|----------|
| **No widget/UI tests** — zero tests in `apps/mobile/test/` or `apps/desktop/test/` | HIGH | Directory listing shows only package-level tests |
| **No multi-device sync test** — only single-device upload/pull | HIGH | `sync_repository_test.dart` has no Device A → Device B scenario |
| **No data persistence across restart test** — each test creates fresh DB | HIGH | All tests use `createDbHarness()` then tear down |
| **No Dart-level idempotency test** — only SQL-level | MEDIUM | No test sends same `operation_id` twice via `uploadBatch` |
| **No Dart-level farm isolation test** — only SQL-level | MEDIUM | All Dart tests use single farm_id |
| **No Dart-level role-based access test** — only SQL-level | MEDIUM | No test verifies worker cannot read payments locally |
| **No concurrent write tests** | MEDIUM | No parallel database access scenarios |
| **No large batch/performance tests** | LOW | All tests use ≤5 records |
| **No expense/inventory/payment provider tests** | MEDIUM | These features have no Dart-level provider tests |
| **No use-case tests** | MEDIUM | `save_*_usecase.dart` files have zero test coverage |
| **No auth flow test** — login, session restore, logout | HIGH | No test for `auth_repository_impl.dart` authentication flow |
| **No edge function test** — `sync_records/index.ts` untested | HIGH | SQL test has broken verification (placeholder UUIDs) |

## 5. Test Quality Assessment

### Strengths
- **Real SQLite via FFI** — not mocked; tests exercise actual SQL behavior
- **Offline-first pattern tested systematically** — every repository has online→cache→offline coverage
- **Sync engine tested at HTTP level** — `MockClient` captures actual request bodies
- **Contract tests ensure API compatibility** — `FakeSupabaseApi` records all calls

### Weaknesses
- **No negative/edge-case coverage for models** — negative counts, future dates, boundary values
- **SQL test P0-3 has broken verification** — line 172-175 uses placeholder UUID, doesn't actually count records
- **Test descriptions in Arabic** — acceptable for the team but reduces international tooling compatibility
- **CI only tests `data` package** — core package tests not in CI
- **No coverage reporting for apps** — only `data` has coverage gate (45%)

## 6. CI Coverage Gate

```yaml
# .github/workflows/ci.yml
Coverage gate: >= 45% of lines for packages/data only
```

**NOT TESTED in CI:**
- `packages/core` (has tests but no CI job)
- `apps/mobile` (no tests exist)
- `apps/desktop` (no tests exist)
- Integration tests (don't exist)
- Security tests (don't exist)
- Sync end-to-end tests (don't exist)
