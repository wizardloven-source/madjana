import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO لطابور المزامنة
class SyncQueueDao {
  static const String _table = 'sync_queue';
  static const _uuid = Uuid();

  Future<void> insert({
    required String tableName,
    required String recordId,
    required Map<String, dynamic> payload,
    required String userId,
  }) async {
    final db = await LocalDatabase.database;
    final now = DateTime.now().toIso8601String();

    await db.insert(_table, {
      'id': _uuid.v4(),
      'table_name': tableName,
      'record_id': recordId,
      'action': 'INSERT',
      'payload': jsonEncode(payload),
      'user_id': userId,
      'attempts': 0,
      'status': 'pending',
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<int> countByStatus(String status) async {
    final db = await LocalDatabase.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_table WHERE status = ?',
      [status],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> updateStatus(String recordId, String status) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {
        'status': status,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'record_id = ?',
      whereArgs: [recordId],
    );
  }

  Future<void> incrementAttempts(String recordId) async {
    final db = await LocalDatabase.database;
    await db.rawUpdate(
      'UPDATE $_table SET attempts = attempts + 1, updated_at = ? WHERE record_id = ?',
      [DateTime.now().toIso8601String(), recordId],
    );
  }

  Future<Map<String, dynamic>?> findByRecordId(String recordId) async {
    final db = await LocalDatabase.database;
    final rows = await db.query(_table, where: 'record_id = ?', whereArgs: [recordId], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> insertError(String error) async {
    final db = await LocalDatabase.database;
    final now = DateTime.now().toIso8601String();
    await db.insert(_table, {
      'id': _uuid.v4(),
      'table_name': 'errors',
      'record_id': _uuid.v4(),
      'action': 'ERROR',
      'payload': jsonEncode({'error': error}),
      'user_id': '',
      'attempts': 0,
      'last_error': error,
      'status': 'failed',
      'created_at': now,
      'updated_at': now,
    });
  }

  /// حذف السجلات المتزامنة القديمة لتقليل حجم الطابور
  Future<void> cleanSynced({int olderThanDays = 7}) async {
    final db = await LocalDatabase.database;
    final cutoff = DateTime.now()
        .subtract(Duration(days: olderThanDays))
        .toIso8601String();
    await db.delete(
      _table,
      where: 'status = ? AND updated_at < ?',
      whereArgs: ['synced', cutoff],
    );
  }
}
