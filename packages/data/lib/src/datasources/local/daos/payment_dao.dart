import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO للمدفوعات/القبض - للمدير فقط
class PaymentDao {
  static const String _table = 'payments';
  static const _uuid = Uuid();
  
  Future<String> insert(PaymentModel payment) async {
    final db = await LocalDatabase.database;
    // ═══ C3 FIX: احترام id المُمرّر (من المُستدعي) بدل توليد UUID جديد ═══
    final id = payment.id ?? _uuid.v4();
    final now = DateTime.now().toIso8601String();

    await db.insert(_table, {
      'id': id,
      'farm_id': payment.farmId,
      'dispatch_id': payment.dispatchId,
      'customer_id': payment.customerId,
      'date': payment.date.toIso8601String().split('T').first,
      'price_per_carton': payment.pricePerCarton,
      'total_due': payment.totalDue,
      'amount_paid': payment.amountPaid,
      'payment_method': payment.paymentMethod.name,
      'currency': payment.currency.name,
      'exchange_rate': payment.exchangeRate,
      'due_date': payment.dueDate?.toIso8601String().split('T').first,
      'notes': payment.notes,
      'manager_id': payment.managerId,
      'created_at': now,
      'updated_at': now,
      'sync_status': SyncStatus.pending.name,
    });

    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: id,
      action: 'INSERT',
      payload: {
        'dispatch_id': payment.dispatchId,
        'customer_id': payment.customerId,
        'date': payment.date.toIso8601String().split('T').first,
        'price_per_carton': payment.pricePerCarton,
        'total_due': payment.totalDue,
        'amount_paid': payment.amountPaid,
        'payment_method': payment.paymentMethod.name,
        'currency': payment.currency.name,
        if (payment.exchangeRate != null) 'exchange_rate': payment.exchangeRate,
        'due_date': payment.dueDate?.toIso8601String().split('T').first,
        'notes': payment.notes,
        'manager_id': payment.managerId,
      },
    );

    return id;
  }
  
  Future<void> update(String id, PaymentModel payment) async {
    final db = await LocalDatabase.database;
    final existing = await db.query(_table, columns: ['version'], where: 'id = ?', whereArgs: [id], limit: 1);
    final ver = existing.isNotEmpty ? (existing.first['version'] as int?) ?? 1 : 1;
    await db.update(
      _table,
      {
        'dispatch_id': payment.dispatchId,
        'customer_id': payment.customerId,
        'date': payment.date.toIso8601String().split('T').first,
        'price_per_carton': payment.pricePerCarton,
        'total_due': payment.totalDue,
        'amount_paid': payment.amountPaid,
        'payment_method': payment.paymentMethod.name,
        'currency': payment.currency.name,
        'exchange_rate': payment.exchangeRate,
        'due_date': payment.dueDate?.toIso8601String().split('T').first,
        'notes': payment.notes,
        'manager_id': payment.managerId,
        'sync_status': SyncStatus.pending.name,
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
        'dispatch_id': payment.dispatchId,
        'customer_id': payment.customerId,
        'date': payment.date.toIso8601String().split('T').first,
        'price_per_carton': payment.pricePerCarton,
        'total_due': payment.totalDue,
        'amount_paid': payment.amountPaid,
        'payment_method': payment.paymentMethod.name,
        'currency': payment.currency.name,
        if (payment.exchangeRate != null) 'exchange_rate': payment.exchangeRate,
        'due_date': payment.dueDate?.toIso8601String().split('T').first,
        'notes': payment.notes,
        'manager_id': payment.managerId,
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
  
  Future<List<PaymentModel>> getAll({
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

  Future<double> getTotalOutstanding({String? farmId}) async {
    final db = await LocalDatabase.database;
    final args = <dynamic>[];

    // الذمم تُحسب لكل فاتورة (dispatch) بتجميع المدفوعات، لا لكل سجل دفع —
    // وإلا تتضاعف عند الدفع بالتقسيط. سجلات بلا فاتورة (قديمة) تُحسب كلٌّ على حدة.
    final farmWhere = farmId != null ? ' AND farm_id = ?' : '';
    if (farmId != null) args..add(farmId)..add(farmId);

    final result = await db.rawQuery(
      'SELECT SUM(t.due - t.paid) as total FROM ('
      '  SELECT dispatch_id, MAX(total_due) as due, SUM(amount_paid) as paid '
      '  FROM $_table '
      '  WHERE dispatch_id IS NOT NULL$farmWhere '
      '  GROUP BY dispatch_id '
      '  HAVING SUM(amount_paid) < MAX(total_due)'
      '  UNION ALL '
      '  SELECT id, total_due as due, amount_paid as paid '
      '  FROM $_table '
      '  WHERE dispatch_id IS NULL AND amount_paid < total_due$farmWhere'
      ') t',
      args,
    );
    return (result.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  /// إجمالي المدفوعات المسجلة لفاتورة واحدة (لتحديد هل اكتمل السداد)
  Future<double> getTotalPaidForDispatch(String dispatchId) async {
    final db = await LocalDatabase.database;
    final result = await db.rawQuery(
      'SELECT SUM(amount_paid) as total FROM $_table WHERE dispatch_id = ?',
      [dispatchId],
    );
    return (result.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getTotalCollected({
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

    final result = await db.rawQuery(
      'SELECT SUM(amount_paid) as total FROM $_table '
      'WHERE ${where.isEmpty ? '1=1' : where.join(' AND ')}',
      args,
    );
    return (result.first['total'] as num?)?.toDouble() ?? 0.0;
  }
  
  PaymentModel _fromMap(Map<String, dynamic> map) {
    return PaymentModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      dispatchId: map['dispatch_id'] as String?,
      customerId: map['customer_id'] as String,
      date: DateTime.parse(map['date'] as String),
      pricePerCarton: (map['price_per_carton'] as num).toDouble(),
      totalDue: (map['total_due'] as num).toDouble(),
      amountPaid: (map['amount_paid'] as num).toDouble(),
      paymentMethod: PaymentMethod.values.firstWhere(
        (e) => e.name == map['payment_method'],
        orElse: () => PaymentMethod.cash,
      ),
      currency: AppCurrency.fromName(map['currency'] as String?),
      exchangeRate: map['exchange_rate'] != null
          ? (map['exchange_rate'] as num).toDouble()
          : null,
      dueDate: map['due_date'] != null
          ? DateTime.tryParse(map['due_date'] as String)
          : null,
      notes: map['notes'] as String?,
      managerId: map['manager_id'] as String,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == (map['sync_status'] ?? 'synced'),
        orElse: () => SyncStatus.synced,
      ),
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'] as String)
          : null,
      version: map['version'] != null ? (map['version'] as num).toInt() : null,
    );
  }
}
