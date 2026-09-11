# 10 — Release Test Matrix

> Defined during audit. To be executed during PHASE 14-15.

## Authentication

| ID | Test | Method | Expected |
|----|------|--------|----------|
| TEST-AUTH-001 | Login with valid phone+PIN | Automated (RPC) | Session established, JWT returned |
| TEST-AUTH-002 | Login with invalid PIN | Automated | `record_login_failure` incremented |
| TEST-AUTH-003 | Login after 5 failures (lockout) | Automated | `check_login_allowed` returns locked |
| TEST-AUTH-004 | Session restore after restart | App-level | Cached session restored |
| TEST-AUTH-005 | Logout clears session | App-level | Session table empty |

## Authorization

| ID | Test | Method | Expected |
|----|------|--------|----------|
| TEST-ROLE-001 | Worker CANNOT read payments | SQL RLS | DENIED |
| TEST-ROLE-002 | Worker CANNOT write payments via sync | SQL RPC | DENIED (sync_can_write) |
| TEST-ROLE-003 | Manager CAN read payments | SQL RLS | ALLOWED |
| TEST-ROLE-004 | System admin CAN read all farms | SQL RLS | ALLOWED |

## Farm Isolation

| ID | Test | Method | Expected |
|----|------|--------|----------|
| TEST-FARM-001 | User A CANNOT read Farm B data | SQL RLS | DENIED |
| TEST-FARM-002 | User A CANNOT write to Farm B via sync | SQL RPC | DENIED |
| TEST-FARM-003 | Multi-farm manager CAN switch farms | App-level | Farm switched |

## Business Operations

| ID | Test | Method | Expected |
|----|------|--------|----------|
| TEST-EGG-001 | Create egg production record | Unit (DAO) | Saved locally, sync queued |
| TEST-EGG-002 | Egg total calculation | Unit (use case) | cartons×360 + trays×30 + loose |
| TEST-MORT-001 | Record mortality | Unit (DAO) | Saved, flock count decremented |
| TEST-MORT-002 | Mortality > flock count rejected | SQL trigger | DENIED |
| TEST-FEED-001 | Record feed consumption | Unit (DAO) | Saved, sync queued |
| TEST-MED-001 | Record medication | Unit (DAO) | Saved with withdrawal days |
| TEST-INV-001 | Inventory transaction | Unit (DAO) | Stock adjusted correctly |
| TEST-PAY-001 | Payment saved | Unit (repo) | Local + remote |
| TEST-EXP-001 | Expense saved | Unit (repo) | Local + remote |
| TEST-DISP-001 | Dispatch recorded | Unit (repo) | Local + sync queued |

## Sync

| ID | Test | Method | Expected |
|----|------|--------|----------|
| TEST-SYNC-001 | Push: local write → sync_queue → server | Unit (sync_test) | synced, version incremented |
| TEST-SYNC-002 | Pull: server changes → local merge | Unit (sync_test) | Local DB updated |
| TEST-SYNC-003 | Network failure → retry with backoff | Unit (sync_test) | Attempts incremented, next_retry_at set |
| TEST-SYNC-004 | Conflict detection (OCC) | SQL test P0-4 | Stale version rejected |
| TEST-SYNC-005 | Idempotency | SQL test P0-3 | No duplicate records |
| TEST-SYNC-006 | **Mobile → Desktop round-trip** | **NOT TESTABLE** (no multi-device env) | **NOT VERIFIED** |
| TEST-SYNC-007 | **Delete propagation** | **NOT TESTABLE** | **NOT VERIFIED** |

## Security

| ID | Test | Method | Expected |
|----|------|--------|----------|
| TEST-SEC-001 | Cross-farm read denied | SQL test P0-1 | DENIED |
| TEST-SEC-002 | Worker financial access denied | SQL test P0-2 | DENIED |
| TEST-SEC-003 | **Self-role escalation blocked** | **NOT TESTABLE** (known P0) | **WILL FAIL** |

## Build

| ID | Test | Method | Expected |
|----|------|--------|----------|
| TEST-BUILD-001 | `dart analyze` on core | CLI | No errors |
| TEST-BUILD-002 | `flutter analyze` on data | CLI | No errors |
| TEST-BUILD-003 | `dart analyze` on domain | CLI | No errors |
| TEST-BUILD-004 | `flutter test` on core | CLI | 9/9 pass |
| TEST-BUILD-005 | `flutter test` on data | CLI | 160/160 pass |

## Data Cleanliness

| ID | Test | Method | Expected |
|----|------|--------|----------|
| TEST-DATA-001 | No demo business data in production code | Grep audit | PASS (confirmed) |
| TEST-DATA-002 | No fake repositories in production paths | Source inspection | PASS (confirmed) |
| TEST-DATA-003 | `.env` not tracked in git | `git ls-files` | PASS (confirmed) |
