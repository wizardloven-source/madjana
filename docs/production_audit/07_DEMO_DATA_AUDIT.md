# 07 — Demo / Mock / Fake / Hardcoded Data Audit

> Read-only audit on 2026-09-11. Every file in the repository was searched.

## VERDICT

**No demo business data exists in production code.** All fake/mock/sample content is isolated to test files. All SQL seeds are legitimate reference data.

---

## 1. TEST ONLY (never reach production)

| File | Content | Classification |
|------|---------|----------------|
| `packages/data/test/sync_repository_test.dart` | `MockClient` ×14, `'http://madjana.test'` | TEST ONLY |
| `packages/data/test/support/fake_supabase_api.dart` (343 lines) | `FakeSupabaseApi`, `_FakeTable`, `_FakeMutation`, `_FakeStorage`, `'https://fake.storage.example/...'` | TEST ONLY |
| `packages/data/test/repositories_impl_rest_test.dart` | `fake.seed(...)`, pins `'1234'`, `initialBirds: 5000`, `totalPayments: 20000` | TEST ONLY |
| `packages/data/test/remote_contract_test.dart` | `fake.seed(...)` ×10, `dummy.jpg`, fake storage URL | TEST ONLY |
| `packages/data/test/daos_rest_test.dart` | Test users `'ب-محدث'`, phone `'9'` | TEST ONLY |
| `supabase/tests/p0_isolation_and_sync_test.sql` | Test UUIDs `...000a/b/c/d`, synthetic users/farms, `"cause":"test"` | TEST ONLY |

## 2. SAFE — Legitimate Reference/Config Data

| File | Content | Classification |
|------|---------|----------------|
| `supabase/migrations/UNIFIED_schema.sql:522-531` | `medicines_catalog` seed (9 medicines: Citric Acid, Amoxicillin, etc.) | SAFE (reference data) |
| `supabase/migrations/UNIFIED_schema.sql:455-464` | `app_settings` bootstrap_token + sync.retention_days=30 | SAFE (config) |
| `supabase/migrations/UNIFIED_schema.sql:1164` | Storage bucket `farm-images` | SAFE (infra) |
| `packages/data/lib/src/datasources/local/daos/medication_dao.dart:187` | `seedCatalog()` syncs medicines catalog to local DB | SAFE (reference) |
| `packages/core/lib/src/constants/app_constants.dart:4-25` | `eggsPerTray=30`, `kgPerBag=24`, `kgPerTon=1000.0` | SAFE (unit conversions) |
| `packages/data/lib/src/datasources/remote/supabase_auth_datasource.dart:279` | `'$uid@users.madjana.local'` synthetic auth email | SAFE (internal) |

## 3. PRODUCTION-REACHING PLACEHOLDERS

| File:Line | Content | Classification | Risk |
|-----------|---------|----------------|------|
| `apps/desktop/lib/features/sync/conflict_monitor_screen.dart:30-35` | `// TODO` + `Future.delayed(1s)` + `_conflicts = []` | PLACEHOLDER | LOW — always shows empty list |
| `apps/desktop/lib/features/onboarding/presentation/new_flock_wizard_screen.dart:272` | `'أدخل基本信息 عن الفوج الجديد'` (mixed Chinese text) | TEXT BUG | LOW — cosmetic |
| `apps/desktop/lib/features/onboarding/presentation/old_flock_wizard_screen.dart:275` | `'أدخل基本信息 عن القطيع القديم'` (mixed Chinese text) | TEXT BUG | LOW — cosmetic |

## 4. ENVIRONMENT FILES (gitignored, not committed)

| File | Content | Status |
|------|---------|--------|
| `apps/mobile/.env` | `SUPABASE_URL=https://qjcgsvsarxfmplmsujfs.supabase.co`, `SUPABASE_ANON_KEY=sb_publishable_...` | git-untracked |
| `apps/desktop/.env` | Same | git-untracked |

Verified via `git ls-files` — no `.env` files are tracked. Anon key is publishable by design.

## 5. ZERO-MATCH PATTERNS

The following patterns returned ZERO matches in production code:
- `"Farm 1"` / `"Farm A"` / `"Demo Farm"` / `"Test Farm"`
- `John Doe` / `Customer 1` / `Example Flock`
- `"10000"` / `"1000 eggs"`
- `test@` / `demo@` email addresses
- Hardcoded UUIDs in Dart source
- `testData` / `fakeData` / `sampleData` / `dummyData`
- `faker` library usage
- Literal phone numbers in production code
- Hardcoded Supabase URL in Dart source files

## 6. HARDCODED BUSINESS VALUES IN PRODUCTION

| File:Line | Value | Context | Risk |
|-----------|-------|---------|------|
| `dashboard_screen.dart:248` | `500` | Feed stock alert threshold (kg) | MEDIUM — not configurable |
| `dashboard_screen.dart:814` | `'80%'` | Production target label | LOW — display only |
| `feed_screen.dart:709` | `'كل كيس 50 كجم'` | Hint text ignoring configurable bag weight | LOW — UI hint |
| `inventory_screen.dart:24,33` | `_bagWeightKg = 50`, `_cartonLowThreshold = 100` | Defaults before farm settings load | LOW — overwritten on load |
