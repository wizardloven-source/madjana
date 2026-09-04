import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO للزبائن - Offline-first
///
/// الزبون الجديد يحفظ محلياً بحالة pend
/// ويُرفع للبعيد عبر طابور المزامنة.
class CustomerDao {
  static const String _table = 'customers';
  static const _uuid = Uuid();

  Future<String> insert(CustomerModel customer) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();

    await db.insert(_table, {
      'id': id,
      'farm_id': customer.farmId,
      'name': customer.name,
      'phone': customer.phone,
      'notes': customer.notes,
      'total_debt': customer.totalDebt,
      'sync_status': SyncStatus.pending.name,
      'created_at': now,
      'updated_at': now,
    });

    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: id,
      action: 'INSERT',
      payload: {
        'name': customer.name,
        'phone': customer.phone,
        'notes': customer.notes,
      },
    );

    return id;
  }

  Future<List<CustomerModel>> getByFarm(String farmId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'farm_id = ?',
      whereArgs: [farmId],
      orderBy: 'name ASC',
    );
    return maps.map(_fromMap).toList();
  }

  Future<List<CustomerModel>> getPendingRecords({int limit = 50}) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'sync_status = ?',
      whereArgs: [SyncStatus.pending.name],
      limit: limit,
    );
    return maps.map(_fromMap).toList();
  }

  Future<int> countPending() async {
    final db = await LocalDatabase.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_table WHERE sync_status = ?',
      [SyncStatus.pending.name],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> updateSyncStatus(String id, SyncStatus status) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {'sync_status': status.name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// استرجاع زبون من السحابة (إدراج أو استبدال لنفس المعرّف)
  Future<void> upsertFromRemote(CustomerModel customer) async {
    final db = await LocalDatabase.database;
    final id = customer.id;
    if (id == null) return;
    await db.insert(
      _table,
      {
        'id': id,
        'farm_id': customer.farmId,
        'name': customer.name,
        'phone': customer.phone,
        'notes': customer.notes,
        'total_debt': customer.totalDebt,
        'sync_status': SyncStatus.synced.name,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> update(CustomerModel customer) async {
    final db = await LocalDatabase.database;
    final existing = await db.query(_table, columns: ['version'], where: 'id = ?', whereArgs: [customer.id], limit: 1);
    final ver = existing.isNotEmpty ? (existing.first['version'] as int?) ?? 1 : 1;
    await db.update(
      _table,
      {
        'name': customer.name,
        'phone': customer.phone,
        'notes': customer.notes,
        'total_debt': customer.totalDebt,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [customer.id],
    );
    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: customer.id!,
      action: 'UPDATE',
      previousVersion: ver,
      payload: {
        'name': customer.name,
        'phone': customer.phone,
        'notes': customer.notes,
      },
    );
  }

  Future<void> deleteById(String id) async {
    final db = await LocalDatabase.database;
    final existing = await db.query(_table, columns: ['version'], where: 'id = ?', whereArgs: [id], limit: 1);
    final ver = existing.isNotEmpty ? (existing.first['version'] as int?) ?? 1 : 1;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: id,
      action: 'DELETE',
      previousVersion: ver,
      payload: {'id': id},
    );
  }

  CustomerModel _fromMap(Map<String, dynamic> map) {
    return CustomerModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      name: map['name'] as String,
      phone: map['phone'] as String,
      notes: map['notes'] as String?,
      totalDebt: (map['total_debt'] as num?)?.toDouble() ?? 0,
    );
  }
}