import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../datasources/local/local_database.dart';

/// تنفيذ مستودع المزامنة (المرحلة 2)
class SyncRepositoryImpl implements SyncRepository {
  final SupabaseClient _supabase;

  SyncRepositoryImpl({
    required dynamic eggDao,
    required dynamic mortalityDao,
    required dynamic feedDao,
    required dynamic dispatchDao,
    required dynamic medicationDao,
    required dynamic customerDao,
    required dynamic paymentDao,
    required dynamic expenseDao,
    required dynamic syncQueueDao,
    required dynamic remoteEgg,
    required dynamic remoteMortality,
    required dynamic remoteFeed,
    required dynamic remoteDispatch,
    required dynamic remoteMedication,
    required dynamic remotePayment,
  }) : _supabase = Supabase.instance.client;

  @override
  Future<List<SyncChangeModel>> getPendingChanges({int limit = 50}) async {
    try {
      final db = await LocalDatabase.database;
      final results = await db.rawQuery('''
        SELECT * FROM sync_queue
        WHERE status = 'pending'
        ORDER BY created_at ASC
        LIMIT ?
      ''', [limit]);

      return results.map((map) => SyncChangeModel.fromMap({
        'id': 0,
        'farm_id': '',
        'table_name': map['table_name'],
        'record_id': map['record_id'],
        'operation': (map['action'] as String? ?? 'INSERT').toLowerCase(),
        'changed_at': map['created_at'] ?? DateTime.now().toIso8601String(),
        'user_id': map['user_id'],
        'payload': map['payload'],
        'status': map['status'] ?? 'pending',
      })).toList();
    } catch (e) {
      return [];
    }
  }

  @override
  Future<void> queueChange(SyncChangeModel change) async {
    try {
      final db = await LocalDatabase.database;
      await db.insert('sync_queue', {
        'id': change.recordId,
        'table_name': change.tableName,
        'record_id': change.recordId,
        'action': change.operation.name.toUpperCase(),
        'payload': change.payload != null
            ? (change.payload is String ? change.payload : '')
            : '',
        'user_id': change.userId ?? '',
        'attempts': 0,
        'status': change.status.name,
        'created_at': change.changedAt.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> markAsSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    try {
      final db = await LocalDatabase.database;
      for (var id in ids) {
        await db.rawUpdate('''
          UPDATE sync_queue
          SET status = 'synced', updated_at = datetime('now')
          WHERE record_id = ?
        ''', [id.toString()]);
      }
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> markAsFailed(int id, String errorMessage) async {
    try {
      final db = await LocalDatabase.database;
      await db.rawUpdate('''
        UPDATE sync_queue
        SET status = 'failed', last_error = ?, updated_at = datetime('now')
        WHERE record_id = ?
      ''', [errorMessage, id.toString()]);
    } catch (e) {
      // silently fail
    }
  }

  @override
  Future<void> cleanupOldSyncedRecords({int daysToKeep = 30}) async {
    try {
      final db = await LocalDatabase.database;
      await db.rawUpdate('''
        DELETE FROM sync_queue
        WHERE status = 'synced'
        AND updated_at < datetime('now', '-$daysToKeep days')
      ''');
    } catch (e) {
      // silently fail
    }
  }

  @override
  Future<int> getPendingCount() async {
    try {
      final db = await LocalDatabase.database;
      final result = await db.rawQuery(
        "SELECT COUNT(*) as count FROM sync_queue WHERE status = 'pending'",
      );
      return result.first['count'] as int? ?? 0;
    } catch (e) {
      return 0;
    }
  }

  @override
  Future<int> getFailedCount() async {
    try {
      final db = await LocalDatabase.database;
      final result = await db.rawQuery(
        "SELECT COUNT(*) as count FROM sync_queue WHERE status = 'failed'",
      );
      return result.first['count'] as int? ?? 0;
    } catch (e) {
      return 0;
    }
  }

  @override
  Future<int> getConflictCount() async {
    try {
      final db = await LocalDatabase.database;
      final result = await db.rawQuery(
        "SELECT COUNT(*) as count FROM sync_queue WHERE status = 'conflict'",
      );
      return result.first['count'] as int? ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// تحديث version السجل في SQLite بعد المزامنة الناجحة
  Future<void> _updateLocalVersion(String recordId, String tableName, int newVersion) async {
    try {
      final db = await LocalDatabase.database;
      final allowedTables = [
        'egg_production', 'mortality', 'feed_consumption',
        'feed_received', 'egg_dispatch', 'medications',
        'customers', 'flocks', 'expenses', 'payments',
      ];
      if (allowedTables.contains(tableName)) {
        await db.rawUpdate(
          'UPDATE $tableName SET version = ? WHERE id = ?',
          [newVersion, recordId],
        );
      }
    } catch (_) {
      // silently fail
    }
  }

  @override
  Future<void> clearAllPending() async {
    try {
      final db = await LocalDatabase.database;
      await db.rawUpdate(
        "DELETE FROM sync_queue WHERE status = 'pending'",
      );
    } catch (e) {
      // silently fail
    }
  }

  @override
  Future<BatchSyncResult> uploadBatch(List<SyncChangeModel> records) async {
    if (records.isEmpty) {
      return BatchSyncResult(successIds: [], failedIds: []);
    }

    try {
      final payload = records.map((r) {
        // استخراج previous_version من payload
        final p = r.payload ?? {};
        return {
          'table_name': r.tableName,
          'record_id': r.recordId,
          'operation': r.operation.name,
          'payload': p,
          'previous_version': p['previous_version'] ?? p['version'],
          'farm_id': r.farmId,
          'user_id': r.userId,
        };
      }).toList();

      final response = await _supabase.functions.invoke(
        'sync_records',
        body: {'records': payload},
      );

      if (response.data != null && response.data is Map) {
        final resp = response.data as Map;
        final affected = resp['affected'] as int? ?? 0;
        final skipped = resp['skipped'] as int? ?? 0;
        final errors = resp['errors'] as int? ?? 0;
        final details = resp['details'] as List<dynamic>? ?? [];

        // استخراج IDs بناءً على التفاصيل
        final successIds = <int>[];
        final failedIds = <int>[];
        final conflictIds = <int>[];

        for (final detail in details) {
          final detailMap = detail as Map;
          final recordIdStr = detailMap['record_id'] as String?;
          final status = detailMap['status'] as String?;

          if (recordIdStr == null) continue;
          final recordId = int.tryParse(recordIdStr) ?? 0;

          switch (status) {
            case 'ok':
              successIds.add(recordId);
              // تحديث version في SQLite
              final newVersion = detailMap['new_version'] as int?;
              if (newVersion != null) {
                await _updateLocalVersion(recordIdStr, resp['table_name']?.toString() ?? '', newVersion);
              }
              break;
            case 'conflict':
              conflictIds.add(recordId);
              break;
            case 'error':
            case 'skipped':
              failedIds.add(recordId);
              break;
          }
        }

        await markAsSynced(successIds);

        for (var id in failedIds) {
          await markAsFailed(id, 'Sync error');
        }

        return BatchSyncResult(
          successIds: successIds,
          failedIds: failedIds,
          conflictIds: conflictIds,
        );
      } else {
        throw Exception('Invalid response from sync function');
      }
    } catch (e) {
      for (var record in records) {
        if (record.id != null) {
          await markAsFailed(record.id!, e.toString());
        }
      }
      return BatchSyncResult(
        successIds: [],
        failedIds: records.map((r) => r.id ?? 0).toList(),
        errorMessage: e.toString(),
      );
    }
  }

  @override
  Future<int> pullRemoteRecords(String farmId) async {
    try {
      final result = await _supabase.rpc(
        'pull_remote_changes',
        params: {'p_farm_id': farmId},
      );

      if (result is int) {
        return result;
      }
      return 0;
    } catch (e) {
      return 0;
    }
  }

  @override
  Future<FullSyncResult> syncNow(String farmId) async {
    try {
      final pending = await getPendingChanges(limit: 100);
      final uploadResult = await uploadBatch(pending);
      final downloadedCount = await pullRemoteRecords(farmId);
      await cleanupOldSyncedRecords(daysToKeep: 30);

      return FullSyncResult(
        uploadedCount: uploadResult.successCount,
        downloadedCount: downloadedCount,
        failedCount: uploadResult.failedCount,
        completedAt: DateTime.now(),
        errorMessage: uploadResult.errorMessage,
      );
    } catch (e) {
      return FullSyncResult(
        uploadedCount: 0,
        downloadedCount: 0,
        failedCount: 1,
        completedAt: DateTime.now(),
        errorMessage: e.toString(),
      );
    }
  }
}
