# 06 — Sync Engine Audit

> Read-only audit on 2026-09-11. Complete sync flow traced through client, Edge Function, and SQL.

## 1. Architecture

```
┌─────────────┐    ┌──────────────┐    ┌───────────────┐    ┌──────────────┐
│  Mobile or   │───>│  sync_queue  │───>│  Edge Function │───>│  PostgreSQL   │
│  Desktop     │    │  (SQLite)    │    │  sync_records  │    │  RPC batch    │
│  App         │    │              │    │  (Deno/TS)     │    │               │
└─────────────┘    └──────────────┘    └───────────────┘    └──────────────┘
       │                                                         │
       │  ┌─────────────────────────────────────────────────┐    │
       │  │  sync_changes table (change log)                 │◄───┘
       │  │  pull_remote_changes RPC → returns delta          │
       │  └─────────────────────────────────────────────────┘
       │                        │
       ▼                        ▼
  Local DB updated         Server state
  (INSERT/UPDATE/DELETE)
```

## 2. Push Flow

1. **DAO insert/update/delete** → writes to SQLite operational table + calls `LocalDatabase.enqueueChange()`
2. **`enqueueChange()`** → strips system fields, generates `operation_id`, inserts into `sync_queue` with `status=pending`
3. **`SyncNotifier` timer** (30s) or manual sync → calls `SyncRepositoryImpl.syncNow()`
4. **`getPendingChanges(limit:100)`** → queries SQLite for pending rows with expired `next_retry_at`
5. **`uploadBatch()`** → builds payload, invokes `functions.invoke('sync_records', body: {records})`
6. **Edge Function** → validates each record, calls `sync_records_batch` RPC per record
7. **`sync_records_batch()`** → idempotency check, role whitelist, farm ownership, OCC version check, column whitelist, write to table + `sync_changes` + `idempotency_log`
8. **Response** → per-record status (ok/conflict/error/skipped)
9. **Client** → marks queue entries as synced/failed/conflict

## 3. Pull Flow

1. **`pullAndMerge(farmId)`** → reads `last_pulled_version` from `sync_state` table
2. Calls `rpc('pull_remote_changes', {p_farm_id, p_from_version})`
3. SQL function returns changes WHERE `server_version > p_from_version` for the farm
4. Client processes in SQLite transaction:
   - `DELETE` → hard delete from local
   - `INSERT` → insert if not exists, update if exists
   - `UPDATE` → update if exists, insert if missing
5. On row failure → `break` (stops processing, maintains `commitPointVersion`)
6. Updates `sync_state.last_pulled_version` to `commitPointVersion`

## 4. Conflict Resolution

### Upload Conflicts (OCC)
- Client sends `previous_version`
- Server checks: if `existing.version > previous_version` → returns `status: 'conflict'`
- Client marks queue entry as `conflict` in `sync_queue`
- Manual resolution by manager: `client_wins`, `server_wins`, or `ignore`
- `merge` resolution is **NOT IMPLEMENTED** (throws exception)

### Pull Conflicts
- None — pull is always authoritative (server wins)

## 5. Retry / Backoff

| Attempts | Wait Time | Action |
|----------|-----------|--------|
| 0→1 | 5s | Stay pending, increment attempts |
| 1→2 | 15s | Stay pending |
| 2→3 | 1min | Stay pending |
| 3→4 | 5min | Stay pending |
| 4+ | 30min | Mark as `failed` permanently |

**Network errors:** Record stays pending with backoff.
**Server per-record errors:** Immediately marked `failed` with generic `'Sync error'` message — no retry.

## 6. Idempotency

1. Client generates unique `operation_id` per queue entry
2. Server checks `idempotency_log` for duplicate `operation_id + user + farm`
3. If found with `status=done` → returns cached result (idempotent replay)
4. If found for different user/farm → returns error

**Verified at SQL level** in `p0_isolation_and_sync_test.sql` P0-3.

## 7. Critical Sync Findings

| # | Severity | Finding | Evidence |
|---|----------|---------|----------|
| 1 | **P0** | **`device_id` never sent** — client doesn't include `device_id` in payload; SQL function reads `v_record->>'device_id'` → NULL; `sync_changes.device_id` always NULL. Desktop SyncCenter device count always 0. | `sync_repository_impl.dart:237-245` — no `device_id` field in upload payload; `sync_records_batch` line 1669 — INSERT omits column |
| 2 | **P0** | **`resyncRequired` has no recovery path** — when client falls behind retention window, `pullAndMerge` returns `resyncRequired: true` forever. Client has no full-resync implementation. Device permanently stuck. | `sync_repository_impl.dart:411-413` — returns but `syncNow` ignores it; no resync flow |
| 3 | **P1** | **Periodic sync stops permanently after 5 consecutive server errors** — `_consecutiveFailures` triggers `_stopPeriodicSync()`. Only restarts on connectivity change or manual `setAutoSync(true)`. If server returns errors but network is fine, sync dead. | `sync_provider.dart:130-132` |
| 4 | **P1** | **Pull overwrites local pending changes** — pull does hard delete and unconditional upsert. If a local record is pending sync and the server has an older version, pull overwrites it with the server version, destroying the local edit. | `sync_repository_impl.dart:436-467` — no check for pending queue before overwriting |
| 5 | **MEDIUM** | **Per-record error messages discarded** — all server errors mapped to generic `'Sync error'`, losing diagnostic info. | `sync_repository_impl.dart:315` |
| 6 | **MEDIUM** | **`detailByRecordId` keyed only on `record_id`** — collisions if same ID in different tables (e.g., delete+insert same UUID). | `sync_repository_impl.dart:267-272` |
| 7 | **MEDIUM** | **Soft delete server / hard delete client** — server uses `deleted_at`, client does `txn.delete()`. Re-pull after delete could resurrect if server soft-delete not respected. | `sync_repository_impl.dart:447-449` |
| 8 | **MEDIUM** | **16 unused constructor parameters** in `SyncRepositoryImpl` — all DAO/remote params are `dynamic` and never stored. | `sync_repository_impl.dart:13-30` |
| 9 | **MEDIUM** | **`SyncQueueDao` orphaned** — provided but never called in production. | `sync_queue_dao.dart` |
| 10 | **LOW** | **`lastSyncAt` set on failure** — in `finally` block, so always updates even on error. | `sync_provider.dart:135` |

## 8. What Is NOT Verified

| Item | Status |
|------|--------|
| Mobile → Cloud → Desktop round-trip | **NOT TESTED** — no multi-device test exists |
| Desktop → Cloud → Mobile round-trip | **NOT TESTED** |
| Bidirectional sync (both devices editing) | **NOT TESTED** |
| Delete propagation across devices | **NOT TESTED** |
| Concurrent modifications | **NOT TESTED** |
| Large batch sync performance | **NOT TESTED** |
| Sync after app restart | **NOT TESTED** at integration level |
| Auth token expiry during sync | **NOT TESTED** |
