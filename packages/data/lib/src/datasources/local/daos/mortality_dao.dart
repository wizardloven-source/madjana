import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO للنفوق
class MortalityDao {
  static const String _table = 'mortality';
  static const _uuid = Uuid();

  Future<String> insert(MortalityModel record) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();

    await db.insert(_table, {
      'id': id,
      'farm_id': record.farmId,
      'flock_id': record.flockId,
      'date': record.date.toIso8601String().split('T').first,
      'count': record.count,
      'reason': record.reason.name,
      'reason_other': record.reasonOther,
      'notes': record.notes,
      'image_url': record.imageUrl,
      'worker_id': record.workerId,
      'sync_status': SyncStatus.pending.name,
      'created_at': DateTime.now().toIso8601String(),
    });

    return id;
  }

  /// جلب العدد الحالي للقطيع (من آخر حالة معروفة محلياً)
  Future<int> getFlockCurrentCount(String flockId) async {
    final db = await LocalDatabase.database;
    final result = await db.query(
      'flocks',
      where: 'id = ?',
      whereArgs: [flockId],
    );
    if (result.isEmpty) return 0;
    return result.first['current_count'] as int? ?? 0;
  }

  /// جلب سجلات اليوم
  Future<List<MortalityModel>> getTodayRecords(String farmId) async {
    final db = await LocalDatabase.database;
    final today = DateTime.now().toIso8601String().split('T').first;

    final maps = await db.query(
      _table,
      where: 'farm_id = ? AND date = ?',
      whereArgs: [farmId, today],
      orderBy: 'created_at DESC',
    );

    return maps.map(_fromMap).toList();
  }

  /// جلب كل السجلات (مع فلاتر)
  Future<List<MortalityModel>> getAll({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final db = await LocalDatabase.database;
    final where = <String>[];
    final args = <dynamic>[];

    if (farmId != null) {
      where.add('farm_id = ?');
      args.add(farmId);
    }
    if (fromDate != null) {
      where.add('date >= ?');
      args.add(fromDate.toIso8601String().split('T').first);
    }
    if (toDate != null) {
      where.add('date <= ?');
      args.add(toDate.toIso8601String().split('T').first);
    }

    final maps = await db.query(
      _table,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'date DESC, created_at DESC',
    );

    return maps.map(_fromMap).toList();
  }

  /// جلب السجلات المعلقة
  Future<List<MortalityModel>> getPendingRecords({int limit = 50}) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'sync_status = ?',
      whereArgs: [SyncStatus.pending.name],
      limit: limit,
    );
    return maps.map(_fromMap).toList();
  }

  /// تحديث حالة المزامنة
  Future<void> updateSyncStatus(String id, SyncStatus status) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {
        'sync_status': status.name,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// استبدال السجل المحلي بالنسخة السحابية (حل التعارض)
  Future<void> replaceWithRemote(MortalityModel model) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {
        'farm_id': model.farmId,
        'flock_id': model.flockId,
        'date': model.date.toIso8601String().split('T').first,
        'count': model.count,
        'reason': model.reason.name,
        'reason_other': model.reasonOther,
        'notes': model.notes,
        'image_url': model.imageUrl,
        'worker_id': model.workerId,
        'sync_status': SyncStatus.synced.name,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [model.id],
    );
  }

  Future<int> countPending() async {
    final db = await LocalDatabase.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_table WHERE sync_status = ?',
      [SyncStatus.pending.name],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// حذف سجل
  Future<void> delete(String id) async {
    final db = await LocalDatabase.database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  MortalityModel _fromMap(Map<String, dynamic> map) {
    return MortalityModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      flockId: map['flock_id'] as String,
      date: DateTime.parse(map['date'] as String),
      count: map['count'] as int,
      reason: MortalityReason.values.firstWhere(
        (e) => e.name == map['reason'],
        orElse: () => MortalityReason.other,
      ),
      reasonOther: map['reason_other'] as String?,
      notes: map['notes'] as String?,
      imageUrl: map['image_url'] as String?,
      workerId: map['worker_id'] as String,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == map['sync_status'],
        orElse: () => SyncStatus.pending,
      ),
    );
  }
}