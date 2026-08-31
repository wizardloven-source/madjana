import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
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
  
  /// الحصول على السجلات المعلقة للمزامنة
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

  /// الحصول على السجلات المعلقة كنماذج ExpenseModel (لمزامنتها)
  Future<List<ExpenseModel>> getPendingModels({int limit = 50}) async {
    final maps = await getPendingRecords(limit: limit);
    return maps.map(_fromMap).toList();
  }
  
  /// تحديث حالة المزامنة
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
  
  /// عدد السجلات المعلقة
  Future<int> countPending() async {
    final db = await LocalDatabase.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_table WHERE sync_status = ?',
      [SyncStatus.pending.name],
    );
    return Sqflite.firstIntValue(result) ?? 0;
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
      'updated_at': DateTime.now().toIso8601String(),
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
        'updated_at': DateTime.now().toIso8601String(),
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
        'created_at': (e.createdAt ?? DateTime.now()).toIso8601String(),
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
