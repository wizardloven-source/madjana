import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO للمخزون (عناصر + حركات)
class InventoryDao {
  static const String _itemsTable = 'inventory_items';
  static const String _txTable = 'inventory_transactions';
  static const _uuid = Uuid();

  // ─────────────── العناصر ───────────────

  Future<List<InventoryItemModel>> getItems(String farmId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _itemsTable,
      where: 'farm_id = ?',
      whereArgs: [farmId],
      orderBy: 'name',
    );
    return maps.map(_itemFromMap).toList();
  }

  Future<InventoryItemModel?> getById(String id) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _itemsTable,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return _itemFromMap(maps.first);
  }

  Future<void> saveItem(InventoryItemModel item) async {
    final db = await LocalDatabase.database;
    final row = {
      'id': item.id ?? _uuid.v4(),
      'farm_id': item.farmId,
      'name': item.name,
      'unit': item.unit.name,
      'quantity': item.quantity,
      'low_stock_threshold': item.lowStockThreshold,
      'notes': item.notes,
      'updated_at': DateTime.now().toIso8601String(),
    };
    await db.insert(
      _itemsTable,
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteItem(String id) async {
    final db = await LocalDatabase.database;
    await db.transaction((txn) async {
      await txn.delete(_txTable, where: 'item_id = ?', whereArgs: [id]);
      await txn.delete(_itemsTable, where: 'id = ?', whereArgs: [id]);
    });
  }

  /// تعديل الكمية وتسجيل الحركة في معاملة واحدة
  Future<InventoryItemModel?> adjustStock({
    required String itemId,
    required bool isInput,
    required double quantity,
    String? note,
    String? userId,
  }) async {
    final db = await LocalDatabase.database;
    final now = DateTime.now().toIso8601String();

    late final InventoryItemModel item;
    try {
      await db.transaction((txn) async {
        final maps = await txn.query(
          _itemsTable,
          where: 'id = ?',
          whereArgs: [itemId],
          limit: 1,
        );
        if (maps.isEmpty) throw StateError('العنصر غير موجود');
        item = _itemFromMap(maps.first);

        final newQty =
            isInput ? item.quantity + quantity : item.quantity - quantity;

        await txn.update(
          _itemsTable,
          {'quantity': newQty, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [itemId],
        );

        await txn.insert(_txTable, {
          'id': _uuid.v4(),
          'item_id': itemId,
          'date': now,
          'type': isInput ? 'in' : 'out',
          'quantity': quantity,
          'note': note,
          'user_id': userId,
        });
      });
    } on StateError {
      return null;
    }
    return item.copyWith(
      quantity: isInput
          ? item.quantity + quantity
          : item.quantity - quantity,
    );
  }

  Future<List<InventoryTransactionModel>> getTransactions(String itemId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _txTable,
      where: 'item_id = ?',
      whereArgs: [itemId],
      orderBy: 'date DESC',
    );
    return maps.map(_txFromMap).toList();
  }

  // ─────────────── التحويل ───────────────

  InventoryItemModel _itemFromMap(Map<String, dynamic> map) {
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

  InventoryTransactionModel _txFromMap(Map<String, dynamic> map) {
    return InventoryTransactionModel(
      id: map['id'] as String,
      itemId: map['item_id'] as String,
      date: DateTime.parse(map['date'] as String),
      isInput: map['type'] == 'in',
      quantity: (map['quantity'] as num).toDouble(),
      note: map['note'] as String?,
      userId: map['user_id'] as String?,
    );
  }
}
