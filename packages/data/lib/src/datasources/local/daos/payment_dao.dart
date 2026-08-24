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
    final id = _uuid.v4();
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
      'due_date': payment.dueDate?.toIso8601String().split('T').first,
      'notes': payment.notes,
      'manager_id': payment.managerId,
      'created_at': now,
    });

    return id;
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

  Future<double> getTotalOutstanding({String? farmId}) async {
    final db = await LocalDatabase.database;
    final where = <String>['amount_paid < total_due'];
    final args = <dynamic>[];
    if (farmId != null) {
      where.add('farm_id = ?');
      args.add(farmId);
    }

    final result = await db.rawQuery(
      'SELECT SUM(total_due - amount_paid) as total FROM $_table '
      'WHERE ${where.join(' AND ')}',
      args,
    );
    return (Sqflite.firstIntValue(result) ?? 0).toDouble();
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
    return (Sqflite.firstIntValue(result) ?? 0).toDouble();
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
      dueDate: map['due_date'] != null
          ? DateTime.tryParse(map['due_date'] as String)
          : null,
      notes: map['notes'] as String?,
      managerId: map['manager_id'] as String,
    );
  }
}