import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import '../local_database.dart';

/// DAO للقطعان
class FlockDao {
  static const String _table = 'flocks';

  Future<List<FlockModel>> getByFarm(String farmId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'farm_id = ? AND status = ?',
      whereArgs: [farmId, FlockStatus.active.name],
      orderBy: 'start_date DESC',
    );
    return maps.map(_fromMap).toList();
  }

  Future<List<FlockModel>> getAll() async {
    final db = await LocalDatabase.database;
    final maps = await db.query(_table, orderBy: 'start_date DESC');
    return maps.map(_fromMap).toList();
  }

  Future<void> saveAll(List<FlockModel> flocks) async {
    final db = await LocalDatabase.database;
    await db.transaction((txn) async {
      await txn.delete(_table);
      for (final f in flocks) {
        await txn.insert(_table, {
          'id': f.id,
          'farm_id': f.farmId,
          'breed': f.breed,
          'start_date': f.startDate.toIso8601String().split('T').first,
          'initial_count': f.initialCount,
          'current_count': f.currentCount,
          'status': f.status.name,
          'sections_count': f.sectionsCount,
        });
      }
    });
  }

  /// إضافة قطيع واحد
  Future<void> insert(FlockModel flock) async {
    final db = await LocalDatabase.database;
    await db.insert(_table, {
      'id': flock.id,
      'farm_id': flock.farmId,
      'breed': flock.breed,
      'start_date': flock.startDate.toIso8601String().split('T').first,
      'initial_count': flock.initialCount,
      'current_count': flock.currentCount,
      'status': flock.status.name,
      'sections_count': flock.sectionsCount,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: flock.id,
      action: 'INSERT',
      payload: {
        'breed': flock.breed,
        'start_date': flock.startDate.toIso8601String().split('T').first,
        'initial_count': flock.initialCount,
        'status': flock.status.name,
        'sections_count': flock.sectionsCount,
      },
    );
  }

  /// إنهاء دورة قطيع محلياً
  Future<void> markEnded(String id) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {'status': FlockStatus.depleted.name},
      where: 'id = ?',
      whereArgs: [id],
    );
    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: id,
      action: 'UPDATE',
      payload: {'status': FlockStatus.depleted.name},
    );
  }

  Future<void> updateCurrentCount(String id, int currentCount) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {'current_count': currentCount},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  FlockModel _fromMap(Map<String, dynamic> map) {
    return FlockModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      breed: map['breed'] as String,
      startDate: DateTime.parse(map['start_date'] as String),
      initialCount: map['initial_count'] as int,
      currentCount: map['current_count'] as int,
      status: FlockStatus.values.firstWhere(
        (e) => e.name == map['status'],
        orElse: () => FlockStatus.active,
      ),
      sectionsCount: map['sections_count'] as int? ?? 1,
    );
  }
}