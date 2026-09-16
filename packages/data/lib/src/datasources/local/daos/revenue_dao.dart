import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

class RevenueDao {
  static const String _table = 'revenue';
  static const _uuid = Uuid();

  Future<List<RevenueModel>> getAll({
    required String farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final db = await LocalDatabase.database;
    final where = StringBuffer('farm_id = ?');
    final args = <dynamic>[farmId];
    if (fromDate != null) {
      where.write(' AND date >= ?');
      args.add(fromDate.toIso8601String().split('T').first);
    }
    if (toDate != null) {
      where.write(' AND date <= ?');
      args.add(toDate.toIso8601String().split('T').first);
    }
    final maps = await db.query(
      _table,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'date DESC',
    );
    return maps.map(_fromMap).toList();
  }

  Future<List<RevenueModel>> getAllByCategory({
    required String farmId,
    required RevenueCategory category,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final db = await LocalDatabase.database;
    final where = StringBuffer('farm_id = ? AND category = ?');
    final args = <dynamic>[farmId, category.name];
    if (fromDate != null) {
      where.write(' AND date >= ?');
      args.add(fromDate.toIso8601String().split('T').first);
    }
    if (toDate != null) {
      where.write(' AND date <= ?');
      args.add(toDate.toIso8601String().split('T').first);
    }
    final maps = await db.query(
      _table,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'date DESC',
    );
    return maps.map(_fromMap).toList();
  }

  Future<List<Map<String, dynamic>>> getPendingRecords({int limit = 50}) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'sync_status = ?',
      whereArgs: [SyncStatus.pending.name],
      orderBy: 'updated_at ASC',
      limit: limit,
    );
    return maps;
  }

  Future<List<RevenueModel>> getPendingModels({int limit = 50}) async {
    final maps = await getPendingRecords(limit: limit);
    return maps.map(_fromMap).toList();
  }

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

  Future<int> countPending() async {
    final db = await LocalDatabase.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_table WHERE sync_status = ?',
      [SyncStatus.pending.name],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<String> insert(RevenueModel revenue) async {
    final db = await LocalDatabase.database;
    final id = revenue.id ?? _uuid.v4();
    await db.insert(_table, {
      'id': id,
      'farm_id': revenue.farmId,
      'date': revenue.date.toIso8601String().split('T').first,
      'category': revenue.category.name,
      'description': revenue.description,
      'amount': revenue.amount,
      'currency': revenue.currency.name,
      'exchange_rate': revenue.exchangeRate,
      'quantity': revenue.quantity,
      'unit': revenue.unit,
      'reference_id': revenue.referenceId,
      'worker_id': revenue.workerId,
      'sync_status': revenue.syncStatus.name,
      // ═══ C1 FIX: كتابة الإصدار ═══
      'version': revenue.version,
      'created_at': (revenue.createdAt ?? DateTime.now()).toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: id,
      action: 'INSERT',
      payload: {
        'date': revenue.date.toIso8601String().split('T').first,
        'category': revenue.category.name,
        'description': revenue.description,
        'amount': revenue.amount,
        'currency': revenue.currency.name,
        if (revenue.exchangeRate != null) 'exchange_rate': revenue.exchangeRate,
        if (revenue.quantity != null) 'quantity': revenue.quantity,
        if (revenue.unit != null) 'unit': revenue.unit,
        if (revenue.referenceId != null) 'reference_id': revenue.referenceId,
        if (revenue.workerId != null) 'worker_id': revenue.workerId,
      },
    );
    return id;
  }

  Future<void> update(String id, RevenueModel revenue) async {
    final db = await LocalDatabase.database;
    final existing = await db.query(_table, columns: ['version'], where: 'id = ?', whereArgs: [id], limit: 1);
    final ver = existing.isNotEmpty ? (existing.first['version'] as int?) ?? 1 : 1;
    await db.update(
      _table,
      {
        'date': revenue.date.toIso8601String().split('T').first,
        'category': revenue.category.name,
        'description': revenue.description,
        'amount': revenue.amount,
        'currency': revenue.currency.name,
        'exchange_rate': revenue.exchangeRate,
        'quantity': revenue.quantity,
        'unit': revenue.unit,
        'reference_id': revenue.referenceId,
        'worker_id': revenue.workerId,
        'sync_status': revenue.syncStatus.name,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: id,
      action: 'UPDATE',
      previousVersion: ver,
      payload: {
        'date': revenue.date.toIso8601String().split('T').first,
        'category': revenue.category.name,
        'description': revenue.description,
        'amount': revenue.amount,
        'currency': revenue.currency.name,
        if (revenue.exchangeRate != null) 'exchange_rate': revenue.exchangeRate,
        if (revenue.quantity != null) 'quantity': revenue.quantity,
        if (revenue.unit != null) 'unit': revenue.unit,
        if (revenue.referenceId != null) 'reference_id': revenue.referenceId,
        if (revenue.workerId != null) 'worker_id': revenue.workerId,
      },
    );
  }

  Future<void> delete(String id) async {
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

  Future<void> saveAll(List<RevenueModel> revenues, String farmId) async {
    final db = await LocalDatabase.database;
    await db.delete(_table, where: 'farm_id = ?', whereArgs: [farmId]);
    for (final r in revenues) {
      if (r.id == null) continue;
      await db.insert(_table, {
        'id': r.id,
        'farm_id': r.farmId,
        'date': r.date.toIso8601String().split('T').first,
        'category': r.category.name,
        'description': r.description,
        'amount': r.amount,
        'currency': r.currency.name,
        'exchange_rate': r.exchangeRate,
        'quantity': r.quantity,
        'unit': r.unit,
        'reference_id': r.referenceId,
        'worker_id': r.workerId,
        'sync_status': SyncStatus.synced.name,
        // ═══ C1 FIX: حفظ الإصدار في saveAll ═══
        'version': r.version,
        'created_at': (r.createdAt ?? DateTime.now()).toIso8601String(),
      });
    }
  }

  RevenueModel _fromMap(Map<String, dynamic> map) {
    return RevenueModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      date: DateTime.parse(map['date'] as String),
      category: RevenueCategory.values.firstWhere(
        (e) => e.name == map['category'],
        orElse: () => RevenueCategory.other,
      ),
      description: map['description'] as String?,
      amount: (map['amount'] as num?)?.toDouble() ?? 0,
      currency: AppCurrency.fromName(map['currency'] as String?),
      exchangeRate: map['exchange_rate'] != null
          ? (map['exchange_rate'] as num).toDouble()
          : null,
      quantity: map['quantity'] != null
          ? (map['quantity'] as num).toDouble()
          : null,
      unit: map['unit'] as String?,
      referenceId: map['reference_id'] as String?,
      workerId: map['worker_id'] as String?,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == map['sync_status'],
        orElse: () => SyncStatus.synced,
      ),
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'] as String)
          : null,
      // ═══ C1 FIX: قراءة الإصدار من قاعدة البيانات ═══
      version: (map['version'] as int?) ?? 1,
    );
  }
}
