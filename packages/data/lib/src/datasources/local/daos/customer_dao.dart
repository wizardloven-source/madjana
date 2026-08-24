import 'package:core/core.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO للزبائن
class CustomerDao {
  static const String _table = 'customers';
  static const _uuid = Uuid();

  Future<String> insert(CustomerModel customer) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();

    await db.insert(_table, {
      'id': id,
      'farm_id': customer.farmId,
      'name': customer.name,
      'phone': customer.phone,
      'notes': customer.notes,
      'total_debt': customer.totalDebt,
      'created_at': DateTime.now().toIso8601String(),
    });

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

  Future<void> updateDebt(String id, double totalDebt) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {'total_debt': totalDebt},
      where: 'id = ?',
      whereArgs: [id],
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