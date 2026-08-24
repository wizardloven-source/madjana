import 'package:core/core.dart';

/// واجهة مستودع التخريج والزبائن
abstract class DispatchRepository {
  /// حفظ تخريج محلياً (Offline-first)
  Future<void> saveLocal(DispatchModel record);

  /// إضافة زبون جديد
  Future<String> addCustomer(CustomerModel customer);

  /// جلب الزبائن
  Future<List<CustomerModel>> getCustomers(String farmId);

  /// جلب كل التخريج
  Future<List<DispatchModel>> getAll({String? farmId, DateTime? fromDate, DateTime? toDate});

  /// مزامنة السجلات المعلقة
  Future<void> syncPendingRecords();

  /// عدد السجلات المعلقة
  Future<int> getPendingCount();
}