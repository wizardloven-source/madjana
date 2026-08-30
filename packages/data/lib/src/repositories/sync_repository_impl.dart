import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// تنفيذ مستودع المزامنة (المرحلة 2)
/// يتعامل مع جدول sync_changes بالأعمدة الجديدة:
/// id, farm_id, table_name, record_id, operation, changed_at, user_id, payload, status, server_version
class SyncRepositoryImpl implements SyncRepository {
  final DatabaseClient _db; // SQLite local database
  final SupabaseClient _supabase;

  SyncRepositoryImpl({
    required DatabaseClient db,
    required SupabaseClient supabase,
  })  : _db = db,
        _supabase = supabase;

  @override
  Future<List<SyncChangeModel>> getPendingChanges({int limit = 50}) async {
    try {
      final results = await _db.rawQuery('''
        SELECT * FROM sync_changes 
        WHERE status = 'pending' 
        ORDER BY changed_at ASC 
        LIMIT ?
      ''', [limit]);

      return results.map((map) => SyncChangeModel.fromMap(map)).toList();
    } catch (e) {
      print('Error fetching pending changes: $e');
      return [];
    }
  }

  @override
  Future<void> queueChange(SyncChangeModel change) async {
    try {
      await _db.insert('sync_changes', change.toMap());
    } catch (e) {
      print('Error queuing change: $e');
      rethrow;
    }
  }

  @override
  Future<void> markAsSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    
    try {
      for (var id in ids) {
        await _db.rawUpdate('''
          UPDATE sync_changes 
          SET status = 'synced', changed_at = datetime('now')
          WHERE id = ?
        ''', [id]);
      }
    } catch (e) {
      print('Error marking as synced: $e');
      rethrow;
    }
  }

  @override
  Future<void> markAsFailed(int id, String errorMessage) async {
    try {
      await _db.rawUpdate('''
        UPDATE sync_changes 
        SET status = 'failed', error_message = ?, changed_at = datetime('now')
        WHERE id = ?
      ''', [errorMessage, id]);
    } catch (e) {
      print('Error marking as failed: $e');
    }
  }

  @override
  Future<void> cleanupOldSyncedRecords({int daysToKeep = 30}) async {
    try {
      await _db.rawUpdate('''
        DELETE FROM sync_changes 
        WHERE status = 'synced' 
        AND changed_at < datetime('now', '-$daysToKeep days')
      ''');
    } catch (e) {
      print('Error cleaning up old records: $e');
    }
  }

  @override
  Future<int> getPendingCount() async {
    try {
      final result = await _db.rawQuery('''
        SELECT COUNT(*) as count FROM sync_changes WHERE status = 'pending'
      ''');
      return result.first['count'] as int? ?? 0;
    } catch (e) {
      print('Error getting pending count: $e');
      return 0;
    }
  }

  @override
  Future<int> getFailedCount() async {
    try {
      final result = await _db.rawQuery('''
        SELECT COUNT(*) as count FROM sync_changes WHERE status = 'failed'
      ''');
      return result.first['count'] as int? ?? 0;
    } catch (e) {
      print('Error getting failed count: $e');
      return 0;
    }
  }

  @override
  Future<int> getConflictCount() async {
    try {
      final result = await _db.rawQuery('''
        SELECT COUNT(*) as count FROM sync_changes WHERE status = 'conflict'
      ''');
      return result.first['count'] as int? ?? 0;
    } catch (e) {
      print('Error getting conflict count: $e');
      return 0;
    }
  }

  @override
  Future<void> clearAllPending() async {
    try {
      await _db.rawUpdate('''
        DELETE FROM sync_changes WHERE status = 'pending'
      ''');
    } catch (e) {
      print('Error clearing pending: $e');
    }
  }

  @override
  Future<BatchSyncResult> uploadBatch(List<SyncChangeModel> records) async {
    if (records.isEmpty) {
      return BatchSyncResult(successIds: [], failedIds: []);
    }

    try {
      // تحويل السجلات إلى تنسيق Edge Function
      final payload = records.map((r) => r.toMap()).toList();
      
      final response = await _supabase.functions.invoke(
        'sync_records',
        body: {'records': payload},
      );

      if (response.data != null && response.data['success_ids'] != null) {
        final successIds = (response.data['success_ids'] as List).map((e) => e as int).toList();
        final failedIds = (response.data['failed_ids'] as List? ?? []).map((e) => e as int).toList();
        final conflictIds = (response.data['conflict_ids'] as List? ?? []).map((e) => e as int).toList();

        // تحديث الحالة محلياً
        await markAsSynced(successIds);
        
        for (var id in failedIds) {
          await markAsFailed(id, 'Server error');
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
      print('Error uploading batch: $e');
      // تعليم الكل كفاشل
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
      // استدعاء دالة SQL لجلب التحديثات من السحابة
      final result = await _supabase.rpc(
        'pull_remote_changes',
        params: {'p_farm_id': farmId},
      );

      if (result is int) {
        return result;
      }
      return 0;
    } catch (e) {
      print('Error pulling remote records: $e');
      return 0;
    }
  }

  @override
  Future<FullSyncResult> syncNow(String farmId) async {
    try {
      final startTime = DateTime.now();
      
      // 1. رفع المعلق
      final pending = await getPendingChanges(limit: 100);
      final uploadResult = await uploadBatch(pending);
      
      // 2. سحب التحديثات من السحابة
      final downloadedCount = await pullRemoteRecords(farmId);
      
      // 3. تنظيف السجلات القديمة
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
