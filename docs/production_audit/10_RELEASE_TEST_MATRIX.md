# 10 — Release Test Matrix

> Defined during audit. Executed during PHASE 11-12 on 2026-09-11.

## Authentication

| ID | Test | Method | Expected | Result |
|----|------|--------|----------|--------|
| TEST-AUTH-001 | Login with valid phone+PIN | Automated (RPC) | Session established, JWT returned | **NOT VERIFIED** (requires staging) |
| TEST-AUTH-002 | Login with invalid PIN | Automated | `record_login_failure` incremented | **NOT VERIFIED** (requires staging) |
| TEST-AUTH-003 | Login after 5 failures (lockout) | Automated | `check_login_allowed` returns locked | **NOT VERIFIED** (requires staging) |
| TEST-AUTH-004 | Session restore after restart | App-level | Cached session restored | **NOT VERIFIED** (requires device) |
| TEST-AUTH-005 | Logout clears session | App-level | Session table empty | **NOT VERIFIED** (requires device) |

## Authorization

| ID | Test | Method | Expected | Result |
|----|------|--------|----------|--------|
| TEST-ROLE-001 | Worker CANNOT read payments | SQL RLS | DENIED | **NOT VERIFIED** (requires staging) |
| TEST-ROLE-002 | Worker CANNOT write payments via sync | SQL RPC | DENIED (sync_can_write) | **NOT VERIFIED** (requires staging) |
| TEST-ROLE-003 | Manager CAN read payments | SQL RLS | ALLOWED | **NOT VERIFIED** (requires staging) |
| TEST-ROLE-004 | System admin CAN read all farms | SQL RLS | ALLOWED | **NOT VERIFIED** (requires staging) |

## Farm Isolation

| ID | Test | Method | Expected | Result |
|----|------|--------|----------|--------|
| TEST-FARM-001 | User A CANNOT read Farm B data | SQL RLS | DENIED | **NOT VERIFIED** (requires staging) |
| TEST-FARM-002 | User A CANNOT write to Farm B via sync | SQL RPC | DENIED | **NOT VERIFIED** (requires staging) |
| TEST-FARM-003 | Multi-farm manager CAN switch farms | App-level | Farm switched | **NOT VERIFIED** (requires device) |

## Business Operations

| ID | Test | Method | Expected | Result |
|----|------|--------|----------|--------|
| TEST-EGG-001 | Create egg production record | Unit (DAO) | Saved locally, sync queued | **✅ PASS** (data tests) |
| TEST-EGG-002 | Egg total calculation | Unit (use case) | cartons×360 + trays×30 + loose | **✅ PASS** (core tests) |
| TEST-MORT-001 | Record mortality | Unit (DAO) | Saved, flock count decremented | **✅ PASS** (data tests) |
| TEST-MORT-002 | Mortality > flock count rejected | SQL trigger | DENIED | **NOT VERIFIED** (requires staging) |
| TEST-FEED-001 | Record feed consumption | Unit (DAO) | Saved, sync queued | **✅ PASS** (data tests) |
| TEST-MED-001 | Record medication | Unit (DAO) | Saved with withdrawal days | **✅ PASS** (data tests) |
| TEST-INV-001 | Inventory transaction | Unit (DAO) | Stock adjusted correctly | **✅ PASS** (data tests) |
| TEST-PAY-001 | Payment saved | Unit (repo) | Local + remote | **✅ PASS** (data tests) |
| TEST-EXP-001 | Expense saved | Unit (repo) | Local + remote | **✅ PASS** (data tests) |
| TEST-DISP-001 | Dispatch recorded | Unit (repo) | Local + sync queued | **✅ PASS** (data tests) |

## Sync

| ID | Test | Method | Expected | Result |
|----|------|--------|----------|--------|
| TEST-SYNC-001 | Push: local write → sync_queue → server | Unit (sync_test) | synced, version incremented | **✅ PASS** (data tests) |
| TEST-SYNC-002 | Pull: server changes → local merge | Unit (sync_test) | Local DB updated | **✅ PASS** (data tests) |
| TEST-SYNC-003 | Network failure → retry with backoff | Unit (sync_test) | Attempts incremented, next_retry_at set | **✅ PASS** (data tests) |
| TEST-SYNC-004 | Conflict detection (OCC) | SQL test P0-4 | Stale version rejected | **NOT VERIFIED** (requires staging) |
| TEST-SYNC-005 | Idempotency | SQL test P0-3 | No duplicate records | **NOT VERIFIED** (requires staging) |
| TEST-SYNC-006 | **Mobile → Desktop round-trip** | **NOT TESTABLE** (no multi-device env) | **NOT VERIFIED** | **NOT VERIFIED** |
| TEST-SYNC-007 | **Delete propagation** | **NOT TESTABLE** | **NOT VERIFIED** | **NOT VERIFIED** |

## Security

| ID | Test | Method | Expected | Result |
|----|------|--------|----------|--------|
| TEST-SEC-001 | Cross-farm read denied | SQL test P0-1 | DENIED | **NOT VERIFIED** (requires staging) |
| TEST-SEC-002 | Worker financial access denied | SQL test P0-2 | DENIED | **NOT VERIFIED** (requires staging) |
| TEST-SEC-003 | Self-role escalation blocked | SQL trigger (P0-001) | DENIED | **NOT VERIFIED** (requires staging) |

## Build

| ID | Test | Method | Expected | Result |
|----|------|--------|----------|--------|
| TEST-BUILD-001 | `dart analyze` on core | CLI | No errors | **✅ PASS** (No issues found) |
| TEST-BUILD-002 | `dart analyze` on data | CLI | No errors | **✅ PASS** (No issues found) |
| TEST-BUILD-003 | `dart analyze` on domain | CLI | No errors | **✅ PASS** (No issues found) |
| TEST-BUILD-004 | `dart test` on core | CLI | 17/17 pass | **✅ PASS** (17/17) |
| TEST-BUILD-005 | `flutter test` on data | CLI | 164/164 pass | **✅ PASS** (164/164) |
| TEST-BUILD-006 | Desktop Windows build | CLI | exe produced | **✅ PASS** (`madjana_desktop.exe`) |
| TEST-BUILD-007 | Mobile Android APK build | CLI | APK produced | **BLOCKED** (no Android SDK/JDK) |

## Data Cleanliness

| ID | Test | Method | Expected | Result |
|----|------|--------|----------|--------|
| TEST-DATA-001 | No demo business data in production code | Grep audit | PASS | **✅ PASS** |
| TEST-DATA-002 | No fake repositories in production paths | Source inspection | PASS | **✅ PASS** |
| TEST-DATA-003 | `.env` not tracked in git | `git ls-files` | PASS | **✅ PASS** |

---

## Summary

| Category | Total | PASS | BLOCKED | NOT VERIFIED |
|----------|-------|------|---------|--------------|
| Authentication | 5 | 0 | 5 (staging) | 0 |
| Authorization | 4 | 0 | 4 (staging) | 0 |
| Farm Isolation | 3 | 0 | 3 (staging) | 0 |
| Business Operations | 10 | 7 | 1 (staging) | 2 (staging) |
| Sync | 7 | 3 | 2 (staging) | 2 (multi-device) |
| Security | 3 | 0 | 3 (staging) | 0 |
| Build | 7 | 5 | 1 (Android SDK) | 1 (mobile) |
| Data Cleanliness | 3 | 3 | 0 | 0 |
| **TOTAL** | **42** | **18** | **19** | **5** |
