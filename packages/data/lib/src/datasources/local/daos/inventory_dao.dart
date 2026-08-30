import 'package:core/core.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO للمخزون (عناصر + حركات) - للمدير فقط
class InventoryDao {
  static const String _itemsTable = 'inventory_items';
  static const String _transactionsTable = 'inventory_transactions';
  static const _uuid = Uuid();

  /// حفظ عنصر مخزون (إدخال أو تحديث)
  Future<void> saveItem(InventoryItemModel item) async {
    final db = await LocalDatabase.database;
    final id = item.id ?? _uuid.v4();
    final now = DateTime.now().toIso8601String();

    final values = <String, dynamic>{
      'id': id,
      'farm_id': item.farmId,
      'name': item.name,
      'unit': item.unit.name,
      'quantity': item.quantity,
      'low_stock_threshold': item.lowStockThreshold,
      'notes': item.notes,
      'updated_at': now,
    };

    final exists = await db.query(
      _itemsTable,
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (exists.isEmpty) {
      await db.insert(_itemsTable, values);
    } else {
      await db.update(_itemsTable, values, where: 'id = ?', whereArgs: [id]);
    }
  }

  /// الحصول على عناصر المخزون لمزرعة معينة
  Future<List<InventoryItemModel>> getItems(String farmId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _itemsTable,
      where: 'farm_id = ?',
      whereArgs: [farmId],
      orderBy: 'name ASC',
    );
    return maps.map(_fromMap).toList();
  }

  /// الحصول على عنصر حسب المعرّف
  Future<InventoryItemModel?> getById(String id) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _itemsTable,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return _fromMap(maps.first);
  }

  /// حذف عنصر مخزون
  Future<void> deleteItem(String id) async {
    final db = await LocalDatabase.database;
    await db.delete(_itemsTable, where: 'id = ?', whereArgs: [id]);
  }

  /// حركات عنصر مخزون معيّن
  Future<List<InventoryTransactionModel>> getTransactions(String itemId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _transactionsTable,
      where: 'item_id = ?',
      whereArgs: [itemId],
      orderBy: 'date ASC',
    );
    return maps
        .map((m) => InventoryTransactionModel.fromJson({
              'id': m['id'],
              'item_id': m['item_id'],
              'date': m['date'],
              'type': m['type'],
              'quantity': m['quantity'],
              'note': m['note'],
              'user_id': m['user_id'],
            }))
        .toList();
  }

  /// إضافة حركة مخزون محلياً
  Future<void> insertTransaction(
      InventoryTransactionModel transaction) async {
    final db = await LocalDatabase.database;
    final id = transaction.id ?? _uuid.v4();
    await db.insert(_transactionsTable, {
      'id': id,
      'item_id': transaction.itemId,
      'date': transaction.date.toIso8601String(),
      'type': transaction.isInput ? 'in' : 'out',
      'quantity': transaction.quantity,
      'note': transaction.note,
      'user_id': transaction.userId,
    });
  }

  InventoryItemModel _fromMap(Map<String, dynamic> map) {
    return InventoryItemModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      name: map['name'] as String,
      unit: InventoryUnit.values.firstWhere(
        (e) => e.name == map['unit'],
        orElse: () => InventoryUnit.piece,
      ),
      quantity: (map['quantity'] as num?)?.toDouble() ?? 0,
      lowStockThreshold:
          (map['low_stock_threshold'] as num?)?.toDouble() ?? 5,
      notes: map['notes'] as String?,
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'] as String)
          : null,
    );
  }
}
