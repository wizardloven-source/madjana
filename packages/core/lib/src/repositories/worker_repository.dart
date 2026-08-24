import 'package:core/core.dart';

/// واجهة مستودع العمال والرواتب
abstract class WorkerRepository {
  /// إنشاء/تحديث عامل
  Future<void> saveWorker(WorkerModel worker);

  /// حذف عامل
  Future<void> deleteWorker(String workerId);

  /// جلب جميع العمال (للمدير فقط)
  Future<List<WorkerModel>> getAllWorkers({String? farmId});

  /// جلب عامل حسب ID
  Future<WorkerModel?> getWorkerById(String workerId);

  /// جلب عمال مدجنة معينة
  Future<List<WorkerModel>> getWorkersByFarm(String farmId);

  /// جلب عمال قطيع معين (العامل يرى فقط القطعان المرتبطة به)
  Future<List<WorkerModel>> getWorkersByFlock(String flockId);

  /// إنشاء كشف راتب
  Future<void> createSalarySlip(SalarySlipModel slip);

  /// تحديث كشف راتب
  Future<void> updateSalarySlip(SalarySlipModel slip);

  /// صرف راتب (تغيير الحالة إلى مدفوع)
  Future<void> paySalary(String slipId);

  /// جلب كشف راتب لعامل في شهر معين
  Future<SalarySlipModel?> getSalarySlip({
    required String workerId,
    required int year,
    required int month,
  });

  /// جلب كل كشوف الراتب لعامل
  Future<List<SalarySlipModel>> getWorkerSalarySlips(String workerId);

  ///_fetch_ كشوف الراتب غير المدفوعة
  Future<List<SalarySlipModel>> getUnpaidSalarySlips({String? farmId});

  /// طلب سلفة
  Future<void> requestAdvance(AdvanceRequestModel request);

  /// تحديث حالة طلب السلفة
  Future<void> updateAdvanceRequest(AdvanceRequestModel request);

  /// جلب طلبات السلف للعامل
  Future<List<AdvanceRequestModel>> getWorkerAdvanceRequests(String workerId);

  /// جلب كل طلبات السلف (للمدير)
  Future<List<AdvanceRequestModel>> getAllAdvanceRequests({String? farmId});

  /// حساب إجمالي الرواتب المستحقة لمدجنة معينة
  Future<double> getTotalOutstandingSalaries({String? farmId});

  /// تسجيل مصروف راتب (يربط بالمدجنة)
  Future<void> recordSalaryExpense({
    required String farmId,
    required String workerId,
    required double amount,
    required SalaryExpenseType type,
    required String slipId,
    DateTime? date,
    String? notes,
  });
}
