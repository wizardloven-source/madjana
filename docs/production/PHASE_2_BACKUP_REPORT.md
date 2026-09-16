# REPORT — Phase 2: Data Reliability & Backup System

## What changed

### New: Local SQLite Backup System (`packages/data/lib/src/backup/`)

1. **`backup_models.dart`** — Types `BackupType`, `BackupStatus`, `BackupMetadata`, `BackupResult`, `RestoreResult`. Metadata captured: id (timestamped timestamp), type, status, createdAt, fileSizeBytes, SHA-256 checksum, DB version, farmId, errorMessage.

2. **`backup_service.dart`** — `BackupService` service:
   - `createBackup()` — takes a consistent snapshot via `VACUUM INTO` (SQLite ≥3.27), enabling snapshot integrity even while other writes are in flight. Falls back to `File.copy` if VACUUM fails. Detects a corrupt/empty backup and refuses to mark it successful.
   - `restoreBackup(id)` — verifies SHA-256 checksum, opens the backup read-only to test table sanity, snapshots current DB as `pre_restore_*`, closes active DB via `LocalDatabase.reset()` before overwrite, reopens with the restored file, counts restored records.
   - `listBackups()` — reads `.meta.json` sidecars, sorted newest-first.
   - `pruneOldBackups(maxCount: 10)` — gravity pruning of oldest successful backup.
   - `deleteBackup()`, `totalBackupSizeBytes()`, `clearAllBackups()`.
   - `BackupService.setBackupDirectory(path)` — overridable storage dir (used by tests and usable on desktop where `path_provider` location differs).

3. **`LocalDatabase.reset()`** — new static: closes the open `Database` handle and nulls the cache so a later open picks up a restored file. Required for `restore` correctness.

4. **Mobile integration** (`apps/mobile`):
   - `features/settings/providers/backup_provider.dart` — `backupServiceProvider`, `BackupState`, `BackupNotifier` (loadBackups / createBackup / restoreBackup / deleteBackup / clearAll), `backupProvider`.
   - `features/settings/presentation/settings_screen.dart` — new "النسخ الاحتياطي" card: create button, restore picker via bottom sheet, confirmation dialog, error/success snackbars, auto-loaded backup list, pruning note.

## Why it changed

The farm records live only in on-device SQLite and the cloud. A corrupt/failed migration or accidental wipe had no recovery path. This adds a cheap, self-contained, integrity-checked snapshot mechanism that works fully offline (no cloud dependency) — satisfying the "offline-first, no breaking sync" constraint.

## Risk assessment

- **Low.** Additive only: new files, no existing table migrations, no schema change, no sync path touched.
- **Medium nuance:** `restoreBackup` closes the live DB (`LocalDatabase.reset()`). In the singular-instance mobile context this is safe; concurrent writers during restore could be affected. Guarded by the UI confirmation dialog.
- **Windows nuance:** `File.copy` throws on an already existing destination — handled by deleting the destination first (errno 183 fix).

## Rollback steps

- Remove `packages/data/lib/src/backup/` and the two exports in `lib/data.dart`.
- Remove `local_database.dart` `reset()` method.
- Remove `backup_provider.dart` and the backup card in `settings_screen.dart`.
- Remove `test/backup_service_test.dart`.

## Test coverage delta

- New `packages/data/test/backup_service_test.dart` — 7 tests covering: full backup creation with valid metadata, listing backups, restore round-trip, DB-file presence/size, checksum-fail corruption detection (restore rejects tampered backup), pruning keeps count (default 10), delete-backup.
- All 7 tests pass (verified under `sqflite_common_ffi`).
- `dart analyze packages/data` — No issues found.
- Full package suite: **+168 passed; 3 pre-existing failures** (verified identical on clean baseline via `git stash` — unrelated to this change: Inventory saveItem remote path, EggProduction syncPendingRecords, Flock createFlock remote upsert).

## Next steps

- Phase 2 remaining: schedule periodic auto-backup hook (e.g. on successful sync, daily), and optionally a cloud backup target.
- Phase 1: CI/CD workflows + versioning.