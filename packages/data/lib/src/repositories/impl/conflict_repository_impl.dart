import 'package:core/core.dart';
import 'package:data/data.dart';
import 'dart:convert';

/// تنفيذ مستودع التعارضات
class ConflictRepositoryImpl implements ConflictRepository {
  final DatabaseService _dbService;

  ConflictRepositoryImpl(this._dbService);

  @override
  Future<List<ConflictModel>> getAllConflicts({String? tableName, String? status}) async {
    final db = await _dbService.database;
    
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
    return records.map((r) => ConflictModel.fromJson(r)).toList();
  }

  @override
  Future<void> resolveConflict(String conflictId, {required String resolution}) async {
    final db = await _dbService.database;
    await db.update(
      'conflicts',
      {
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
    final db = await _dbService.database;
    await db.update(
      'conflicts',
      {
        'status': 'ignored',
        'ignored_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [conflictId],
    );
  }

  @override
  Future<void> addConflict(ConflictModel conflict) async {
    final db = await _dbService.database;
    await db.insert('conflicts', conflict.toJson());
  }

  @override
  Future<ConflictModel?> getConflictById(String id) async {
    final db = await _dbService.database;
    final records = await db.query('conflicts', where: 'id = ?', whereArgs: [id]);
    
    if (records.isEmpty) return null;
    return ConflictModel.fromJson(records.first);
  }
}
