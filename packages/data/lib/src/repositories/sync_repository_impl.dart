import 'dart:convert';
import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
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
      final now = DateTime.now().toIso8601String();
      final results = await db.rawQuery('''
        SELECT * FROM sync_queue
        WHERE status = 'pending'
          AND (next_retry_at IS NULL OR next_retry_at <= ?)
        ORDER BY created_at ASC
        LIMIT ?
      ''', [now, limit]);

      final currentUser = _supabase.auth.currentUser;
      final farmId = currentUser?.userMetadata?['farm_id']?.toString() ?? '';

      return results.map((map) => SyncChangeModel.fromMap({
        'id': 0,
        'farm_id': farmId.isNotEmpty ? farmId : (map['farm_id'] ?? ''),
        'table_name': map['table_name'],
        'record_id': map['record_id'],
        'operation': (map['action'] as String? ?? 'INSERT').toLowerCase(),
        'changed_at': map['created_at'] ?? DateTime.now().toIso8601String(),
        'user_id': map['user_id'],
        'payload': map['payload'],
        'status': map['status'] ?? 'pending',
        'attempts': map['attempts'] ?? 0,
        'error_message': map['last_error'],
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
        'payload': change.payload != null ? jsonEncode(change.payload) : '',
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
  Future<void> markAsSynced(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      final db = await LocalDatabase.database;
      for (var id in ids) {
        await db.rawUpdate('''
          UPDATE sync_queue
          SET status = 'synced', updated_at = datetime('now')
          WHERE record_id = ?
        ''', [id]);
      }
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> markAsFailed(String id, String errorMessage) async {
    try {
      final db = await LocalDatabase.database;
      await db.rawUpdate('''
        UPDATE sync_queue
        SET status = 'failed', last_error = ?, updated_at = datetime('now')
        WHERE record_id = ?
      ''', [errorMessage, id]);
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
  Future<int> getSyncedCount() async {
    try {
      final db = await LocalDatabase.database;
      final result = await db.rawQuery(
        "SELECT COUNT(*) as count FROM sync_queue WHERE status = 'synced'",
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
        final p = r.payload ?? {};
        return {
          'table_name': r.tableName,
          'record_id': r.recordId,
          'operation': r.operation.name,
          'operation_id': r.recordId,
          'data': p,
          'previous_version': p['previous_version'] ?? p['version'],
        };
      }).toList();

      final response = await _supabase.functions.invoke(
        'sync_records',
        body: {'records': payload},
      );

      if (response.data != null && response.data is Map) {
        final resp = response.data as Map;
        final details = resp['details'] as List<dynamic>? ?? [];

        final successIds = <String>[];
        final failedIds = <String>[];
        final conflictIds = <String>[];

        for (final detail in details) {
          final detailMap = detail as Map;
          final recordIdStr = detailMap['record_id'] as String?;
          final status = detailMap['status'] as String?;
          final tableName = detailMap['table_name'] as String?;

          if (recordIdStr == null) continue;

          switch (status) {
            case 'ok':
              successIds.add(recordIdStr);
              final newVersion = detailMap['new_version'] as int?;
              if (newVersion != null && tableName != null) {
                await _updateLocalVersion(recordIdStr, tableName, newVersion);
              }
              break;
            case 'conflict':
              conflictIds.add(recordIdStr);
              break;
            case 'error':
            case 'skipped':
              failedIds.add(recordIdStr);
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
      // خطأ شبكة/خادم عام: لا نُحوِّل العمليات إلى failed فوراً.
      // نعيدها إلى pending مع زيادة attempts + جدولة retry لاحق.
      final msg = e.toString();
      final now = DateTime.now();
      for (var record in records) {
        final attempts = record.attempts + 1;
        final shouldKeepPending = attempts < _maxRetryAttempts;
        if (shouldKeepPending) {
          await _markPendingWithRetry(record.recordId, attempts, msg, now);
        } else {
          await markAsFailed(record.recordId, msg);
        }
      }
      return BatchSyncResult(
        successIds: [],
        failedIds: records.map((r) => r.recordId).toList(),
        errorMessage: e.toString(),
      );
    }
  }

  static const int _maxRetryAttempts = 5;

  /// يعيد العملية إلى pending مع زيادة عدد المحاولات وتحديد وقت إعادة المحاولة
  Future<void> _markPendingWithRetry(String recordId, int attempts, String error, DateTime now) async {
    try {
      final db = await LocalDatabase.database;
      final nextRetry = _backoffDelay(attempts);
      final nextRetryAt = now.add(nextRetry).toIso8601String();
      await db.rawUpdate('''
        UPDATE sync_queue
        SET status = 'pending',
            attempts = ?,
            last_error = ?,
            last_error_code = 'RETRYABLE',
            next_retry_at = ?,
            updated_at = ?
        WHERE record_id = ?
      ''', [attempts, error, nextRetryAt, now.toIso8601String(), recordId]);
    } catch (_) {}
  }

  /// فاصل زمني متزايد (exp backoff) للمحاولة المطلوبة:
  /// 1→5s, 2→15s, 3→1m, 4→5m, 5→30m
  static Duration _backoffDelay(int attempt) {
    const table = [0, 5, 15, 60, 300, 1800];
    final index = attempt < table.length ? attempt : table.length - 1;
    return Duration(seconds: table[index]);
  }

  @override
  Future<PullResult> pullAndMerge(String farmId) async {
    try {
      final db = await LocalDatabase.database;

      // 1) قراءة آخر إصدار مُستلم
      final stateRows = await db.query('sync_state', limit: 1);
      final lastVersion = stateRows.isNotEmpty
          ? (stateRows.first['last_pulled_version'] as int?) ?? 0
          : 0;

      // 2) استدعاء RPC للحصول على التغييرات الجديدة
      final response = await _supabase.rpc(
        'pull_remote_changes',
        params: {
          'p_farm_id': farmId,
          'p_from_version': lastVersion,
        },
      );

      if (response == null || response is! Map) {
        return const PullResult();
      }

      final latestVersion = (response['latest_version'] as num?)?.toInt() ?? 0;
      final changes = (response['changes'] as List?) ?? [];

      if (changes.isEmpty) {
        return PullResult(latestVersion: latestVersion);
      }

      // 3) دمج كل تغيير في SQLite
      int applied = 0;
      int conflicts = 0;

      await db.transaction((txn) async {
        for (final change in changes) {
          final c = change as Map<String, dynamic>;
          final tableName = c['table_name'] as String;
          final recordId = c['record_id'] as String;
          final operation = c['operation'] as String;
          final payload = c['payload'] as Map<String, dynamic>? ?? {};

          try {
            // فحص الوجود المحلي
            final existing = await txn.query(
              tableName,
              where: 'id = ?',
              whereArgs: [recordId],
              limit: 1,
            );
            final exists = existing.isNotEmpty;

            if (operation == 'DELETE') {
              if (exists) {
                await txn.delete(tableName, where: 'id = ?', whereArgs: [recordId]);
                applied++;
              }
            } else if (operation == 'INSERT') {
              if (!exists) {
                await _insertRecord(txn, tableName, recordId, payload);
                applied++;
              } else {
                // السجل موجود مسبقاً (تم إنشاؤه محلياً)
                // نُحدّثه بالبيانات البعيدة إذا كان الإصدار الأعلى
                await _updateRecord(txn, tableName, recordId, payload);
                applied++;
              }
            } else if (operation == 'UPDATE') {
              if (exists) {
                await _updateRecord(txn, tableName, recordId, payload);
                applied++;
              } else {
                // السجل غير موجود محلياً — نُنشئه (coming from another device)
                await _insertRecord(txn, tableName, recordId, payload);
                applied++;
              }
            }
          } catch (_) {
            conflicts++;
          }
        }
      });

      // 4) تحديث آخر إصدار مُستلم
      await db.rawInsert(
        '''INSERT OR REPLACE INTO sync_state (id, last_pulled_version, updated_at)
           VALUES ('local', ?, ?)''',
        [latestVersion, DateTime.now().toIso8601String()],
      );

      return PullResult(
        downloadedCount: changes.length,
        appliedCount: applied,
        conflictCount: conflicts,
        latestVersion: latestVersion,
      );
    } catch (e) {
      return PullResult(errorMessage: e.toString());
    }
  }

  /// إدراج سجل من البيانات البعيدة في SQLite
  Future<void> _insertRecord(
    DatabaseExecutor txn,
    String tableName,
    String recordId,
    Map<String, dynamic> payload,
  ) async {
    // اكتشاف الأعمدة المدعومة في الجدول المحلي
    final columns = await txn.rawQuery('PRAGMA table_info($tableName)');
    final localCols = columns.map((c) => c['name'] as String).toSet();

    // إضافة id إذا لم يكن موجوداً في payload
    final data = Map<String, dynamic>.from(payload)..['id'] = recordId;

    // فلترة الأعمدة غير المدعومة
    final filtered = <String, dynamic>{};
    for (final entry in data.entries) {
      if (localCols.contains(entry.key)) {
        filtered[entry.key] = entry.value;
      }
    }

    if (filtered.isEmpty) return;

    final cols = filtered.keys.join(', ');
    final placeholders = List.filled(filtered.length, '?').join(', ');
    final values = filtered.values.toList();

    await txn.rawInsert(
      'INSERT OR IGNORE INTO $tableName ($cols) VALUES ($placeholders)',
      values,
    );
  }

  /// تحديث سجل من البيانات البعيدة في SQLite
  Future<void> _updateRecord(
    DatabaseExecutor txn,
    String tableName,
    String recordId,
    Map<String, dynamic> payload,
  ) async {
    final columns = await txn.rawQuery('PRAGMA table_info($tableName)');
    final localCols = columns.map((c) => c['name'] as String).toSet();

    final data = Map<String, dynamic>.from(payload)..['id'] = recordId;

    final setParts = <String>[];
    final values = <dynamic>[];

    for (final entry in data.entries) {
      if (localCols.contains(entry.key) && entry.key != 'id') {
        setParts.add('${entry.key} = ?');
        values.add(entry.value);
      }
    }

    if (setParts.isEmpty) return;

    values.add(recordId);
    await txn.rawUpdate(
      'UPDATE $tableName SET ${setParts.join(', ')} WHERE id = ?',
      values,
    );
  }

  @override
  Future<FullSyncResult> syncNow(String farmId) async {
    try {
      final pending = await getPendingChanges(limit: 100);
      final uploadResult = await uploadBatch(pending);
      final pullResult = await pullAndMerge(farmId);
      await cleanupOldSyncedRecords(daysToKeep: 30);

      final result = FullSyncResult(
        uploadedCount: uploadResult.successCount,
        downloadedCount: pullResult.appliedCount,
        failedCount: uploadResult.failedCount + pullResult.conflictCount,
        completedAt: DateTime.now(),
        errorMessage: uploadResult.errorMessage ?? pullResult.errorMessage,
      );

      await _recordHistory(result);
      return result;
    } catch (e) {
      final result = FullSyncResult(
        uploadedCount: 0,
        downloadedCount: 0,
        failedCount: 1,
        completedAt: DateTime.now(),
        errorMessage: e.toString(),
      );
      await _recordHistory(result);
      return result;
    }
  }

  @override
  Future<List<SyncHistoryEntry>> getSyncHistory({int limit = 20}) async {
    try {
      final db = await LocalDatabase.database;
      final rows = await db.query(
        'sync_history',
        orderBy: 'created_at DESC',
        limit: limit,
      );
      return rows.map(SyncHistoryEntry.fromMap).toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> _recordHistory(FullSyncResult result) async {
    try {
      final db = await LocalDatabase.database;
      await db.insert('sync_history', {
        'id': DateTime.now().microsecondsSinceEpoch.toString(),
        'created_at': result.completedAt.toIso8601String(),
        'uploaded': result.uploadedCount,
        'downloaded': result.downloadedCount,
        'failed': result.failedCount,
        'errored_tables': '',
        'error_message': result.errorMessage,
      });
    } catch (_) {
      // السجل غير حرج — لا يمنع دورة المزامنة
    }
  }
}
