import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO للعلف (استهلاك + استلام)
class FeedDao {
  static const _uuid = Uuid();

  // ===================== استهلاك العلف =====================
  Future<String> insertConsumption(FeedConsumptionModel record) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();

    await db.insert('feed_consumption', {
      'id': id,
      'farm_id': record.farmId,
      'date': record.date.toIso8601String().split('T').first,
      'entry_mode': record.entryMode.name,
      'bags_count': record.bagsCount,
      'quantity_kg': record.quantityKg,
      'worker_id': record.workerId,
      'sync_status': SyncStatus.pending.name,
      'created_at': DateTime.now().toIso8601String(),
    });

    return id;
  }

  Future<List<FeedConsumptionModel>> getTodayConsumption(String farmId) async {
    final db = await LocalDatabase.database;
    final today = DateTime.now().toIso8601String().split('T').first;

    final maps = await db.query(
      'feed_consumption',
      where: 'farm_id = ? AND date = ?',
      whereArgs: [farmId, today],
    );

    return maps.map(_consumptionFromMap).toList();
  }

  Future<List<FeedConsumptionModel>> getPendingConsumption({int limit = 50}) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      'feed_consumption',
      where: 'sync_status = ?',
      whereArgs: [SyncStatus.pending.name],
      limit: limit,
    );
    return maps.map(_consumptionFromMap).toList();
  }

  Future<List<FeedConsumptionModel>> getAllConsumption({
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
      'feed_consumption',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'date DESC',
    );
    return maps.map(_consumptionFromMap).toList();
  }

  Future<void> updateConsumptionSyncStatus(String id, SyncStatus status) async {
    final db = await LocalDatabase.database;
    await db.update(
      'feed_consumption',
      {'sync_status': status.name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> countPendingConsumption() async {
    final db = await LocalDatabase.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM feed_consumption WHERE sync_status = ?',
      [SyncStatus.pending.name],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> countPendingReceived() async {
    final db = await LocalDatabase.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM feed_received WHERE sync_status = ?',
      [SyncStatus.pending.name],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  FeedConsumptionModel _consumptionFromMap(Map<String, dynamic> map) {
    return FeedConsumptionModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      date: DateTime.parse(map['date'] as String),
      entryMode: FeedEntryMode.values.firstWhere((e) => e.name == map['entry_mode']),
      bagsCount: map['bags_count'] as int? ?? 0,
      quantityKg: (map['quantity_kg'] as num).toDouble(),
      workerId: map['worker_id'] as String,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == map['sync_status'],
        orElse: () => SyncStatus.pending,
      ),
    );
  }

  // ===================== استلام العلف =====================
  Future<String> insertReceived(Map<String, dynamic> data) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();

    await db.insert('feed_received', {
      'id': id,
      'farm_id': data['farm_id'],
      'date': data['date'],
      'entry_mode': data['entry_mode'],
      'quantity': data['quantity'],
      'quantity_kg': data['quantity_kg'],
      'feed_type': data['feed_type'],
      'supplier': data['supplier'],
      'invoice_number': data['invoice_number'],
      if (data['price_per_kg'] != null) 'price_per_kg': data['price_per_kg'],
      'notes': data['notes'],
      'worker_id': data['worker_id'] ?? '',
      'sync_status': SyncStatus.pending.name,
      'created_at': DateTime.now().toIso8601String(),
    });

    return id;
  }

  Future<List<FeedReceivedModel>> getPendingReceived({int limit = 50}) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      'feed_received',
      where: 'sync_status = ?',
      whereArgs: [SyncStatus.pending.name],
      limit: limit,
    );
    return maps.map(_receivedFromMap).toList();
  }

  Future<void> updateReceivedSyncStatus(String id, SyncStatus status) async {
    final db = await LocalDatabase.database;
    await db.update(
      'feed_received',
      {'sync_status': status.name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// تسجيل سعر الكيلوغرام من المدير (سطح المكتب)
  Future<void> updateReceivedPrice(String id, double pricePerKg) async {
    final db = await LocalDatabase.database;
    await db.update(
      'feed_received',
      {'price_per_kg': pricePerKg},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<FeedReceivedModel>> getAllReceived({
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
      'feed_received',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'date DESC',
    );
    return maps.map(_receivedFromMap).toList();
  }

  FeedReceivedModel _receivedFromMap(Map<String, dynamic> map) {
    return FeedReceivedModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      date: DateTime.parse(map['date'] as String),
      entryMode: FeedEntryMode.values.firstWhere(
        (e) => e.name == map['entry_mode'],
      ),
      quantity: (map['quantity'] as num).toDouble(),
      quantityKg: (map['quantity_kg'] as num).toDouble(),
      feedType: FeedType.values.firstWhere((e) => e.name == map['feed_type']),
      supplier: map['supplier'] as String?,
      invoiceNumber: map['invoice_number'] as String?,
      notes: map['notes'] as String?,
      pricePerKg: (map['price_per_kg'] as num?)?.toDouble(),
    );
  }
}