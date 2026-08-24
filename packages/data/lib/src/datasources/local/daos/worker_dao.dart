import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO للعمال والرواتب
class WorkerDao {
  static const String _workersTable = 'workers';
  static const String _salarySlipsTable = 'salary_slips';
  static const String _advanceRequestsTable = 'advance_requests';
  static const String _salaryExpensesTable = 'salary_expenses';
  static const _uuid = Uuid();

  /// ==================== العمال ====================

  Future<String> insertWorker(WorkerModel worker) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();

    await db.insert(_workersTable, {
      'id': id,
      'name': worker.name,
      'phone': worker.phone,
      'farm_id': worker.farmId,
      'assigned_flock_ids': worker.assignedFlockIds.join(','),
      'base_salary': worker.baseSalary,
      'hire_date': worker.hireDate.toIso8601String().split('T').first,
      'is_active': worker.isActive ? 1 : 0,
      'created_at': now,
    });

    return id;
  }

  Future<void> updateWorker(WorkerModel worker) async {
    final db = await LocalDatabase.database;
    await db.update(
      _workersTable,
      {
        'name': worker.name,
        'phone': worker.phone,
        'farm_id': worker.farmId,
        'assigned_flock_ids': worker.assignedFlockIds.join(','),
        'base_salary': worker.baseSalary,
        'hire_date': worker.hireDate.toIso8601String().split('T').first,
        'is_active': worker.isActive ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [worker.id],
    );
  }

  Future<void> deleteWorker(String workerId) async {
    final db = await LocalDatabase.database;
    await db.delete(_workersTable, where: 'id = ?', whereArgs: [workerId]);
  }

  Future<List<WorkerModel>> getAllWorkers({String? farmId}) async {
    final db = await LocalDatabase.database;
    final where = <String>[];
    final args = <dynamic>[];

    if (farmId != null) {
      where.add('farm_id = ?');
      args.add(farmId);
    }

    final maps = await db.query(
      _workersTable,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC',
    );

    return maps.map(_workerFromMap).toList();
  }

  Future<WorkerModel?> getWorkerById(String workerId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _workersTable,
      where: 'id = ?',
      whereArgs: [workerId],
    );

    if (maps.isEmpty) return null;
    return _workerFromMap(maps.first);
  }

  Future<List<WorkerModel>> getWorkersByFarm(String farmId) async {
    return getAllWorkers(farmId: farmId);
  }

  Future<List<WorkerModel>> getWorkersByFlock(String flockId) async {
    final db = await LocalDatabase.database;
    // البحث عن العمال الذين يحتوي assigned_flock_ids على flockId
    final maps = await db.query(
      _workersTable,
      where: 'assigned_flock_ids LIKE ?',
      whereArgs: ['%$flockId%'],
    );

    return maps.map(_workerFromMap).toList();
  }

  WorkerModel _workerFromMap(Map<String, dynamic> map) {
    return WorkerModel(
      id: map['id'] as String,
      name: map['name'] as String,
      phone: map['phone'] as String,
      farmId: map['farm_id'] as String?,
      assignedFlockIds: (map['assigned_flock_ids'] as String?)
              ?.split(',')
              .where((s) => s.isNotEmpty)
              .toList() ??
          [],
      baseSalary: (map['base_salary'] as num?)?.toDouble() ?? 0.0,
      hireDate: DateTime.parse(map['hire_date'] as String),
      isActive: (map['is_active'] as int) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  /// ==================== كشوف الراتب ====================

  Future<String> insertSalarySlip(SalarySlipModel slip) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();

    await db.insert(_salarySlipsTable, {
      'id': id,
      'worker_id': slip.workerId,
      'worker_name': slip.workerName,
      'year': slip.year,
      'month': slip.month,
      'base_salary': slip.baseSalary,
      'advances': slip.advances,
      'bonuses': slip.bonuses,
      'deductions': slip.deductions,
      'net_salary': slip.netSalary,
      'is_paid': slip.isPaid ? 1 : 0,
      'paid_at': slip.isPaid ? slip.paidAt.toIso8601String() : null,
      'notes': slip.notes,
      'created_at': now,
    });

    return id;
  }

  Future<void> updateSalarySlip(SalarySlipModel slip) async {
    final db = await LocalDatabase.database;
    await db.update(
      _salarySlipsTable,
      {
        'advances': slip.advances,
        'bonuses': slip.bonuses,
        'deductions': slip.deductions,
        'net_salary': slip.netSalary,
        'is_paid': slip.isPaid ? 1 : 0,
        'paid_at': slip.isPaid ? slip.paidAt.toIso8601String() : null,
        'notes': slip.notes,
      },
      where: 'id = ?',
      whereArgs: [slip.id],
    );
  }

  Future<void> paySalary(String slipId) async {
    final db = await LocalDatabase.database;
    final now = DateTime.now().toIso8601String();
    await db.update(
      _salarySlipsTable,
      {
        'is_paid': 1,
        'paid_at': now,
      },
      where: 'id = ?',
      whereArgs: [slipId],
    );
  }

  Future<SalarySlipModel?> getSalarySlip({
    required String workerId,
    required int year,
    required int month,
  }) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _salarySlipsTable,
      where: 'worker_id = ? AND year = ? AND month = ?',
      whereArgs: [workerId, year, month],
    );

    if (maps.isEmpty) return null;
    return _salarySlipFromMap(maps.first);
  }

  Future<List<SalarySlipModel>> getWorkerSalarySlips(String workerId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _salarySlipsTable,
      where: 'worker_id = ?',
      whereArgs: [workerId],
      orderBy: 'year DESC, month DESC',
    );

    return maps.map(_salarySlipFromMap).toList();
  }

  Future<List<SalarySlipModel>> getUnpaidSalarySlips({String? farmId}) async {
    final db = await LocalDatabase.database;
    final where = <String>['is_paid = 0'];
    final args = <dynamic>[];

    // إذا كان farmId موجود، نحتاج لربط جدول العمال
    if (farmId != null) {
      final result = await db.rawQuery('''
        SELECT ss.* FROM $_salarySlipsTable ss
        INNER JOIN $_workersTable w ON ss.worker_id = w.id
        WHERE ${where.join(' AND ')} AND w.farm_id = ?
        ORDER BY ss.year DESC, ss.month DESC
      ''', [...args, farmId]);
      return result.map(_salarySlipFromMap).toList();
    }

    final maps = await db.query(
      _salarySlipsTable,
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'year DESC, month DESC',
    );

    return maps.map(_salarySlipFromMap).toList();
  }

  SalarySlipModel _salarySlipFromMap(Map<String, dynamic> map) {
    return SalarySlipModel(
      id: map['id'] as String,
      workerId: map['worker_id'] as String,
      workerName: map['worker_name'] as String,
      year: map['year'] as int,
      month: map['month'] as int,
      baseSalary: (map['base_salary'] as num).toDouble(),
      advances: (map['advances'] as num?)?.toDouble() ?? 0.0,
      bonuses: (map['bonuses'] as num?)?.toDouble() ?? 0.0,
      deductions: (map['deductions'] as num?)?.toDouble() ?? 0.0,
      netSalary: (map['net_salary'] as num).toDouble(),
      isPaid: (map['is_paid'] as int) == 1,
      paidAt: map['paid_at'] != null
          ? DateTime.parse(map['paid_at'] as String)
          : null,
      notes: map['notes'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  /// ==================== طلبات السلف ====================

  Future<String> insertAdvanceRequest(AdvanceRequestModel request) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();

    await db.insert(_advanceRequestsTable, {
      'id': id,
      'worker_id': request.workerId,
      'worker_name': request.workerName,
      'amount': request.amount,
      'reason': request.reason,
      'request_date': request.requestDate.toIso8601String(),
      'status': request.status.name,
      'manager_notes': request.managerNotes,
      'reviewed_at': request.reviewedAt?.toIso8601String(),
      'created_at': now,
    });

    return id;
  }

  Future<void> updateAdvanceRequest(AdvanceRequestModel request) async {
    final db = await LocalDatabase.database;
    await db.update(
      _advanceRequestsTable,
      {
        'status': request.status.name,
        'manager_notes': request.managerNotes,
        'reviewed_at': request.reviewedAt?.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [request.id],
    );
  }

  Future<List<AdvanceRequestModel>> getWorkerAdvanceRequests(
      String workerId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _advanceRequestsTable,
      where: 'worker_id = ?',
      whereArgs: [workerId],
      orderBy: 'created_at DESC',
    );

    return maps.map(_advanceRequestFromMap).toList();
  }

  Future<List<AdvanceRequestModel>> getAllAdvanceRequests({
    String? farmId,
  }) async {
    final db = await LocalDatabase.database;

    if (farmId != null) {
      final result = await db.rawQuery('''
        SELECT ar.* FROM $_advanceRequestsTable ar
        INNER JOIN $_workersTable w ON ar.worker_id = w.id
        WHERE w.farm_id = ?
        ORDER BY ar.created_at DESC
      ''', [farmId]);
      return result.map(_advanceRequestFromMap).toList();
    }

    final maps = await db.query(
      _advanceRequestsTable,
      orderBy: 'created_at DESC',
    );

    return maps.map(_advanceRequestFromMap).toList();
  }

  AdvanceRequestModel _advanceRequestFromMap(Map<String, dynamic> map) {
    return AdvanceRequestModel(
      id: map['id'] as String,
      workerId: map['worker_id'] as String,
      workerName: map['worker_name'] as String,
      amount: (map['amount'] as num).toDouble(),
      reason: map['reason'] as String,
      requestDate: DateTime.parse(map['request_date'] as String),
      status: AdvanceRequestStatus.values.firstWhere(
        (e) => e.name == map['status'],
        orElse: () => AdvanceRequestStatus.pending,
      ),
      managerNotes: map['manager_notes'] as String?,
      reviewedAt: map['reviewed_at'] != null
          ? DateTime.parse(map['reviewed_at'] as String)
          : null,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  /// ==================== مصروفات الرواتب ====================

  Future<void> recordSalaryExpense({
    required String farmId,
    required String workerId,
    required double amount,
    required SalaryExpenseType type,
    required String slipId,
    DateTime? date,
    String? notes,
  }) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();
    final now = date?.toIso8601String() ?? DateTime.now().toIso8601String();

    await db.insert(_salaryExpensesTable, {
      'id': id,
      'farm_id': farmId,
      'worker_id': workerId,
      'slip_id': slipId,
      'amount': amount,
      'type': type.name,
      'date': now.split('T').first,
      'notes': notes,
      'created_at': now,
    });
  }

  Future<double> getTotalOutstandingSalaries({String? farmId}) async {
    final db = await LocalDatabase.database;

    if (farmId != null) {
      final result = await db.rawQuery('''
        SELECT SUM(ss.net_salary) as total FROM $_salarySlipsTable ss
        INNER JOIN $_workersTable w ON ss.worker_id = w.id
        WHERE ss.is_paid = 0 AND w.farm_id = ?
      ''', [farmId]);
      return (Sqflite.firstIntValue(result) ?? 0).toDouble();
    }

    final result = await db.rawQuery(
      'SELECT SUM(net_salary) as total FROM $_salarySlipsTable WHERE is_paid = 0',
    );
    return (Sqflite.firstIntValue(result) ?? 0).toDouble();
  }
}
