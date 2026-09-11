# Release Candidate Report

> Madjana Production Readiness Audit
> Audit Date: 2026-09-11
> Commit: Current HEAD

## Repository

- **Monorepo:** Flutter monorepo (no melos)
- **Apps:** mobile (Flutter, Android), desktop (Flutter, Windows)
- **Packages:** core (Dart), data (Flutter), domain (Dart — empty barrel)
- **Backend:** Supabase (PostgreSQL + GoTrue + Edge Functions + Storage)
- **SDK:** Dart >=3.12.0, Flutter >=3.44.0

## Test Results

| Suite | Tests | Result |
|-------|-------|--------|
| `packages/core` (dart test) | 9 | **ALL PASSED** |
| `packages/data` (flutter test) | 160 | **ALL PASSED** |
| **TOTAL** | **169** | **ALL PASSED** |

## Analysis

| Package | Result |
|---------|--------|
| core | PASS (no issues) |
| data | TIMEOUT (analysis too slow for 180s limit; tests pass) |
| domain | PASS (no issues) |
| mobile | TIMEOUT (analysis too slow for 180s limit) |
| desktop | TIMEOUT (analysis too slow for 180s limit) |

## CI/CD

| Item | Status |
|------|--------|
| CI Workflow | Present (`.github/workflows/ci.yml`) |
| CI Coverage | data package only, >=45% line coverage gate |
| CI Missing | core package tests, mobile build, desktop build, integration tests |

## Security

| Check | Result |
|-------|--------|
| No secrets in source | **PASS** — `.env` gitignored, no hardcoded keys |
| No service-role exposure | **PASS** — only anon key used in clients |
| RLS enabled | **PARTIAL** — policies defined but explicit `ENABLE ROW LEVEL SECURITY` only on 3 tables |
| Role enforcement (server) | **FAIL** — self-role escalation via `users_update_self` RLS (P0-001) |
| Bootstrap security | **FAIL** — token not verified (P0-002) |
| Lockout enforcement | **FAIL** — client-enforced only, bypassable via direct GoTrue calls (P1-006) |

## Demo Data

| Check | Result |
|-------|--------|
| No demo business data | **PASS** |
| No fake repositories in production | **PASS** |
| `.env` not tracked | **PASS** |
| Reference data (medicines catalog) | **SAFE** |

## Sync

| Check | Result |
|-------|--------|
| Push flow implemented | **PASS** |
| Pull flow implemented | **PASS** |
| Idempotency (SQL) | **PASS** |
| OCC conflict detection (SQL) | **PASS** |
| Farm isolation (SQL) | **PASS** |
| device_id populated | **FAIL** — always NULL (P0-003) |
| resyncRequired recovery | **FAIL** — no recovery path (P1-008) |
| Bidirectional mobile↔desktop | **NOT VERIFIED** — no multi-device test env |
| Delete propagation | **NOT VERIFIED** |

## Known Limitations

1. Self-role escalation via RLS (P0) — **MUST FIX before production**
2. Bootstrap token not verified (P0) — **MUST FIX before production**
3. device_id never populated (P0) — **MUST FIX before production**
4. Approvals cross-farm data leak (P0) — **MUST FIX before production**
5. Emergency screen sends nothing (P0) — **MUST FIX or remove before production**
6. 4-digit PIN brute-force risk (P1) — **SHOULD FIX**
7. Desktop manager can create system_admin (P1) — **SHOULD FIX**
8. No widget/integration tests for either app
9. No multi-device sync verification possible in current test environment
10. No `supabase/config.toml` for local development

## Open P2/P3 Issues

See `08_PRODUCTION_BLOCKERS.md` — 17 P2 and 10 P3 issues documented.

---

## RELEASE STATUS

**BLOCKED**

## CRITICAL BLOCKERS

**5**

## HIGH BLOCKERS

**6**

## MEDIUM ISSUES

**17**

## LOW ISSUES

**10**

## TEST RESULTS

| Area | Result |
|------|--------|
| Analysis (core) | PASS |
| Analysis (data) | TIMEOUT (tests pass) |
| Analysis (domain) | PASS |
| Analysis (mobile) | TIMEOUT |
| Analysis (desktop) | TIMEOUT |
| Unit (core) | PASS (9/9) |
| Unit (data) | PASS (160/160) |
| Integration | **NOT VERIFIED** (no tests exist) |
| Sync (Dart) | PASS (tests exist and pass) |
| Sync (SQL) | **NOT VERIFIED** (requires running Supabase) |
| Security (SQL) | **NOT VERIFIED** (requires running Supabase) |
| Security (Dart) | **NOT VERIFIED** (requires auth env) |
| Database | **NOT VERIFIED** (requires running Supabase) |
| Build (mobile) | **NOT VERIFIED** (Flutter SDK timeout) |
| Build (desktop) | **NOT VERIFIED** (Flutter SDK timeout) |
| Demo Data | PASS (codebase clean) |

## PRODUCTION DECISION

**NOT APPROVED**

### Required before production:
1. Fix all 5 P0 blockers (BLOCKER-001 through BLOCKER-005)
2. Fix at least P1-006 (lockout), P1-007 (role escalation in UI), P1-010 (mortality data loss), P1-011 (division by zero)
3. Run SQL tests against a staging Supabase instance
4. Run analysis on all packages (currently timing out)
5. Verify mobile and desktop builds
