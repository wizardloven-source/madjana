import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO لتسويات رصيد المخزون (تعديل رصيد يدوي - المدير فقط)
///
/// يعتمد على حقول الجدول الواقعية في local_database.dart:
///   id, farm_id, stock_type (eggs|cartons|feed), delta_qty, reason,
///   notes, date, manager_id, sync_status, version, deleted_at,
///   created_at, updated_at
/// تُدفع التعديلات للمزامنة عبر LocalDatabase.enqueueChange مثل بقيّة
/// الجداول (داد sync_can_write/read في الخادم يستقبل بنية delta_qty).
class StockAdjustmentsDao {
  static const String _table = 'stock_adjustments';
  static const _uuid = Uuid();

  /// إدراج تسوية جديدة (توليد id إن لم يُمرَّر) مع تسجيلها للمزامنة
  Future<String> insert(Map<String, dynamic> data) async {
    final db = await LocalDatabase.database;
    final id = data['id'] as String? ?? _uuid.v4();
    final now = DateTime.now().toIso8601String();

    final values = <String, dynamic>{
      'id': id,
      'farm_id': data['farm_id'],
      'stock_type': data['stock_type'],
      'delta_qty': data['delta_qty'],
      'reason': data['reason'],
      'notes': data['notes'],
      'date':
          (data['date'] as String?) ?? DateTime.now().toIso8601String().split('T').first,
      'manager_id': data['manager_id'],
      'sync_status': data['sync_status'] ?? 'synced',
      'version': 1,
      'deleted_at': null,
      'created_at': now,
      'updated_at': now,
    };

    await db.insert(_table, values, conflictAlgorithm: ConflictAlgorithm.replace);

    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: id,
      action: 'INSERT',
      payload: {
        'farm_id': data['farm_id'],
        'stock_type': data['stock_type'],
        'delta_qty': data['delta_qty'],
        'reason': data['reason'],
        'notes': data['notes'],
        'date': (data['date'] as String?) ??
            DateTime.now().toIso8601String().split('T').first,
        'manager_id': data['manager_id'],
      },
    );

    return id;
  }

  /// جلب جميع التسويات (اختيارياً لمزرعة/مدير محددين)
  Future<List<Map<String, dynamic>>> getAll({String? farmId, String? managerId}) async {
    final db = await LocalDatabase.database;
    final where = <String>['deleted_at IS NULL'];
    final args = <dynamic>[];

    if (farmId != null) {
      where.add('farm_id = ?');
      args.add(farmId);
    }
    if (managerId != null) {
      where.add('manager_id = ?');
      args.add(managerId);
    }

    return db.query(
      _table,
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'date DESC, created_at DESC',
    );
  }

  /// حذف ناعم (tombstone) مع تسجيل الحذف للمزامنة
  Future<void> softDelete(String id) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {
        'deleted_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'sync_status': 'pending',
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: id,
      action: 'DELETE',
      payload: {'id': id},
    );
  }

  /// السجلات المعلقة للمزامنة
  Future<List<Map<String, dynamic>>> getPending({int limit = 50}) async {
    final db = await LocalDatabase.database;
    return db.query(
      _table,
      where: 'sync_status = ? AND deleted_at IS NULL',
      whereArgs: ['pending'],
      orderBy: 'updated_at ASC',
      limit: limit,
    );
  }

  /// تحديث حالة المزامنة المحلية بعد نجاح النقل للخادم
  Future<void> markSynced(String id) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {
        'sync_status': 'synced',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// مجموع التغيير الصافي لتسويات نوع معيّن (لمجال اليوم أو فترة)
  Future<double> totalDelta(String stockType, {DateTime? from, DateTime? to}) async {
    final db = await LocalDatabase.database;
    final where = <String>['stock_type = ?', 'deleted_at IS NULL'];
    final args = <dynamic>[stockType];

    if (from != null) {
      where.add('date >= ?');
      args.add(from.toIso8601String().split('T').first);
    }
    if (to != null) {
      where.add('date <= ?');
      args.add(to.toIso8601String().split('T').first);
    }

    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(delta_qty), 0) AS total FROM $_table '
      'WHERE ${where.join(' AND ')}',
      args,
    );
    return (rows.first['total'] as num).toDouble();
  }
}
