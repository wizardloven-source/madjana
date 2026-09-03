import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO لإنتاج البيض - التعامل مع SQLite
class EggProductionDao {
  static const String _table = 'egg_production';
  static const _uuid = Uuid();

  /// حفظ سجل جديد (مع توليد ID محلي)
  Future<String> insert(EggProductionModel record) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();

    await db.insert(_table, {
      'id': id,
      'farm_id': record.farmId,
      'flock_id': record.flockId,
      'date': record.date.toIso8601String().split('T').first,
      'cartons': record.cartons,
      'trays': record.trays,
      'loose_eggs': record.looseEggs,
      'total_eggs': record.totalEggs,
      'broken_eggs': record.brokenEggs,
      'dirty_eggs': record.dirtyEggs,
      'tray_weight_kg': record.trayWeightKg,
      'section_no': record.sectionNo,
      'worker_id': record.workerId,
      'sync_status': SyncStatus.pending.name,
      'created_at': now,
      'updated_at': now,
    });

    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: id,
      action: 'INSERT',
      payload: {
        'flock_id': record.flockId,
        'date': record.date.toIso8601String().split('T').first,
        'cartons': record.cartons,
        'trays': record.trays,
        'loose_eggs': record.looseEggs,
        'broken_eggs': record.brokenEggs,
        'dirty_eggs': record.dirtyEggs,
        'tray_weight_kg': record.trayWeightKg,
        'section_no': record.sectionNo,
        'worker_id': record.workerId,
      },
    );

    return id;
  }

  /// جلب سجلات اليوم
  Future<List<EggProductionModel>> getTodayRecords(String farmId) async {
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

  /// جلب سجل حسب التاريخ (لزر "نسخ من أمس")
  Future<EggProductionModel?> getByDate(String farmId, DateTime date) async {
    final db = await LocalDatabase.database;
    final dateStr = date.toIso8601String().split('T').first;

    final maps = await db.query(
      _table,
      where: 'farm_id = ? AND date = ?',
      whereArgs: [farmId, dateStr],
      limit: 1,
    );

    return maps.isEmpty ? null : _fromMap(maps.first);
  }

  /// جلب السجلات المعلقة للمزامنة
  Future<List<EggProductionModel>> getPendingRecords({int limit = 50}) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'sync_status = ?',
      whereArgs: [SyncStatus.pending.name],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return maps.map(_fromMap).toList();
  }

  /// تحديث حالة المزامنة
  Future<void> updateSyncStatus(String id, SyncStatus status) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {'sync_status': status.name, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// استبدال السجل المحلي بالنسخة السحابية (حل التعارض)
  Future<void> replaceWithRemote(EggProductionModel model) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {
        'farm_id': model.farmId,
        'flock_id': model.flockId,
        'date': model.date.toIso8601String().split('T').first,
        'cartons': model.cartons,
        'trays': model.trays,
        'loose_eggs': model.looseEggs,
        'broken_eggs': model.brokenEggs,
        'dirty_eggs': model.dirtyEggs,
        'total_eggs': model.totalEggs,
        'tray_weight_kg': model.trayWeightKg,
        'section_no': model.sectionNo,
        'worker_id': model.workerId,
        'sync_status': SyncStatus.synced.name,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [model.id],
    );
  }

  /// عد السجلات المعلقة
  Future<int> countPending() async {
    final db = await LocalDatabase.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_table WHERE sync_status = ?',
      [SyncStatus.pending.name],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// جلب كل السجلات (مع فلاتر)
  Future<List<EggProductionModel>> getAll({
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

  /// حذف سجل
  Future<void> delete(String id) async {
    final db = await LocalDatabase.database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: id,
      action: 'DELETE',
      payload: {'id': id},
    );
  }

  /// تحويل Map إلى Model
  EggProductionModel _fromMap(Map<String, dynamic> map) {
    return EggProductionModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      flockId: map['flock_id'] as String,
      date: DateTime.parse(map['date'] as String),
      cartons: map['cartons'] as int,
      trays: map['trays'] as int,
      looseEggs: map['loose_eggs'] as int,
      brokenEggs: map['broken_eggs'] as int? ?? 0,
      dirtyEggs: map['dirty_eggs'] as int? ?? 0,
      trayWeightKg: (map['tray_weight_kg'] as num?)?.toDouble(),
      sectionNo: map['section_no'] as int?,
      workerId: map['worker_id'] as String,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == map['sync_status'],
        orElse: () => SyncStatus.pending,
      ),
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'] as String)
          : null,
    );
  }
}