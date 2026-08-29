import 'package:core/core.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO لطلبات التخريج
class DispatchRequestDao {
  static const String _table = 'dispatch_requests';
  static const _uuid = Uuid();

  Future<String> insert(DispatchRequestModel record) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();

    await db.insert(_table, {
      'id': id,
      'farm_id': record.farmId,
      'customer_id': record.customerId,
      'requested_cartons': record.requestedCartons,
      'requested_trays': record.requestedTrays,
      'notes': record.notes,
      'status': record.status,
      'created_at': record.createdAt.toIso8601String(),
      'updated_at': record.updatedAt?.toIso8601String(),
    });

    return id;
  }

  Future<List<DispatchRequestModel>> getAll({String? farmId}) async {
    final db = await LocalDatabase.database;
    final where = <String>[];
    final args = <dynamic>[];

    if (farmId != null) {
      where.add('farm_id = ?');
      args.add(farmId);
    }

    final maps = await db.query(
      _table,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC',
    );
    return maps.map(_fromMap).toList();
  }

  Future<List<DispatchRequestModel>> getByFarm(String farmId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'farm_id = ?',
      whereArgs: [farmId],
      orderBy: 'created_at DESC',
    );
    return maps.map(_fromMap).toList();
  }

  Future<void> updateStatus(String id, String status) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {
        'status': status,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    final db = await LocalDatabase.database;
    await db.delete(
      _table,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  DispatchRequestModel _fromMap(Map<String, dynamic> map) {
    return DispatchRequestModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      customerId: map['customer_id'] as String,
      requestedCartons: map['requested_cartons'] as int? ?? 0,
      requestedTrays: map['requested_trays'] as int? ?? 0,
      notes: map['notes'] as String?,
      status: map['status'] as String? ?? 'pending',
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'] as String)
          : null,
    );
  }
}
