import 'package:core/core.dart';
import 'package:data/data.dart';
import 'dart:convert';

/// تنفيذ مستودع التعارضات (SQLite محلي عبر LocalDatabase)
class ConflictRepositoryImpl implements ConflictRepository {
  const ConflictRepositoryImpl();

  @override
  Future<List<ConflictModel>> getAllConflicts({String? tableName, String? status}) async {
    final db = await LocalDatabase.database;

    var query = 'SELECT * FROM conflicts WHERE 1=1';
    final args = <dynamic>[];

    if (tableName != null) {
      query += ' AND table_name = ?';
      args.add(tableName);
    }

    if (status != null) {
      query += ' AND status = ?';
      args.add(status);
    }

    query += ' ORDER BY created_at DESC';

    final records = await db.rawQuery(query, args);
    return records.map(_fromRow).toList();
  }

  @override
  Future<void> resolveConflict(String conflictId, {required String resolution}) async {
    final db = await LocalDatabase.database;
    await db.update(
      'conflicts',
      <String, dynamic>{
        'status': 'resolved',
        'resolution': resolution,
        'resolved_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [conflictId],
    );
  }

  @override
  Future<void> ignoreConflict(String conflictId) async {
    final db = await LocalDatabase.database;
    await db.update(
      'conflicts',
      <String, dynamic>{
        'status': 'ignored',
        'ignored_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [conflictId],
    );
  }

  @override
  Future<void> addConflict(ConflictModel conflict) async {
    final db = await LocalDatabase.database;
    await db.insert('conflicts', {
      'id': conflict.id,
      'table_name': conflict.tableName,
      'record_id': conflict.recordId,
      'client_data': jsonEncode(conflict.clientData),
      'server_data': conflict.serverData != null ? jsonEncode(conflict.serverData) : null,
      'status': conflict.status,
      'suggested_action': conflict.suggestedAction,
      'created_at': conflict.createdAt.toIso8601String(),
    });
  }

  @override
  Future<ConflictModel?> getConflictById(String id) async {
    final db = await LocalDatabase.database;
    final records = await db.query('conflicts', where: 'id = ?', whereArgs: [id]);

    if (records.isEmpty) return null;
    return _fromRow(records.first);
  }

  /// تحويل صف SQLite إلى نموذج، مع فك ترميز حقلَي client_data/server_data
  ConflictModel _fromRow(Map<String, dynamic> row) {
    Map<String, dynamic> decode(String? raw) {
      if (raw == null || raw.isEmpty) return <String, dynamic>{};
      try {
        return Map<String, dynamic>.from(jsonDecode(raw));
      } catch (_) {
        return <String, dynamic>{};
      }
    }

    return ConflictModel(
      id: row['id'] as String,
      tableName: row['table_name'] as String,
      recordId: row['record_id'] as String,
      clientData: decode(row['client_data'] as String?),
      serverData: row['server_data'] != null ? decode(row['server_data'] as String?) : null,
      status: row['status'] as String? ?? 'pending',
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ?? DateTime.now(),
      suggestedAction: row['suggested_action'] as String? ?? 'manual_review',
    );
  }
}
