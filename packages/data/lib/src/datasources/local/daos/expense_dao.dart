import 'package:core/core.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO للمصروفات
class ExpenseDao {
  static const String _table = 'expenses';
  static const _uuid = Uuid();

  Future<List<ExpenseModel>> getAll({
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

  Future<String> insert(ExpenseModel expense) async {
    final db = await LocalDatabase.database;
    final id = expense.id ?? _uuid.v4();
    await db.insert(_table, {
      'id': id,
      'farm_id': expense.farmId,
      'date': expense.date.toIso8601String().split('T').first,
      'category': expense.category.name,
      'description': expense.description,
      'amount': expense.amount,
      'sync_status': expense.syncStatus.name,
      'created_at': (expense.createdAt ?? DateTime.now()).toIso8601String(),
    });
    return id;
  }

  Future<void> update(String id, ExpenseModel expense) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {
        'date': expense.date.toIso8601String().split('T').first,
        'category': expense.category.name,
        'description': expense.description,
        'amount': expense.amount,
        'sync_status': expense.syncStatus.name,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    final db = await LocalDatabase.database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  /// حفظ مجموعة قادمة من الخادم (تحديث الكاش المحلي)
  Future<void> saveAll(List<ExpenseModel> expenses, String farmId) async {
    final db = await LocalDatabase.database;
    await db.delete(_table, where: 'farm_id = ?', whereArgs: [farmId]);
    for (final e in expenses) {
      if (e.id == null) continue;
      await db.insert(_table, {
        'id': e.id,
        'farm_id': e.farmId,
        'date': e.date.toIso8601String().split('T').first,
        'category': e.category.name,
        'description': e.description,
        'amount': e.amount,
        'sync_status': SyncStatus.synced.name,
        'created_at':
            (e.createdAt ?? DateTime.now()).toIso8601String(),
      });
    }
  }

  ExpenseModel _fromMap(Map<String, dynamic> map) {
    return ExpenseModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      date: DateTime.parse(map['date'] as String),
      category: ExpenseCategory.values.firstWhere(
        (e) => e.name == map['category'],
        orElse: () => ExpenseCategory.other,
      ),
      description: map['description'] as String?,
      amount: (map['amount'] as num?)?.toDouble() ?? 0,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == map['sync_status'],
        orElse: () => SyncStatus.synced,
      ),
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'] as String)
          : null,
    );
  }
}
