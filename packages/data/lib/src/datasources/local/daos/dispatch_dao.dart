import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO للتخريج (الفواتير)
class DispatchDao {
  static const String _table = 'egg_dispatch';
  static const _uuid = Uuid();

  Future<String> insert(DispatchModel record) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();

    await db.insert(_table, {
      'id': id,
      'farm_id': record.farmId,
      'date': record.date.toIso8601String().split('T').first,
      'customer_id': record.customerId,
      'cartons': record.cartons,
      'trays': record.trays,
      'total_eggs': record.totalEggs,
      'tray_weight_kg': record.trayWeightKg,
      'notes': record.notes,
      'payment_status': record.paymentStatus.name,
      'worker_id': record.workerId,
      'sync_status': SyncStatus.pending.name,
      'created_at': now,
    });

    return id;
  }

  Future<List<DispatchModel>> getPendingRecords({int limit = 50}) async {
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

  Future<List<DispatchModel>> getAll({
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

  Future<void> updatePaymentStatus(String id, PaymentStatus status) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {'payment_status': status.name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  DispatchModel _fromMap(Map<String, dynamic> map) {
    return DispatchModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      date: DateTime.parse(map['date'] as String),
      customerId: map['customer_id'] as String,
      cartons: map['cartons'] as int? ?? 0,
      trays: map['trays'] as int? ?? 0,
      trayWeightKg: (map['tray_weight_kg'] as num?)?.toDouble(),
      notes: map['notes'] as String?,
      paymentStatus: PaymentStatus.values.firstWhere(
        (e) => e.name == map['payment_status'],
        orElse: () => PaymentStatus.unpaid,
      ),
      workerId: map['worker_id'] as String,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == map['sync_status'],
        orElse: () => SyncStatus.pending,
      ),
    );
  }
}