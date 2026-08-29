import 'package:core/core.dart';

/// واجهة مستودع التخريج والزبائن
abstract class DispatchRepository {
  /// حفظ تخريج محلياً (Offline-first)
  Future<void> saveLocal(DispatchModel record);

  /// إضافة زبون جديد (Offline-first: محلياً أولاً ثم يرفع للبعيد)
  Future<String> addCustomer(CustomerModel customer);

  /// جلب الزبائن
  Future<List<CustomerModel>> getCustomers(String farmId);

  /// سحب الزبائن من السحابة وتحديث الكاش المحلي
  Future<List<CustomerModel>> syncCustomersFromRemote(String farmId);

  /// تعديل زبون (محلياً + البعيد عند الاتصال)
  Future<void> updateCustomer(CustomerModel customer);

  /// حذف زبون (محلياً + البعيد عند الاتصال)
  Future<void> deleteCustomer(String id);

  /// جلب كل التخريج
  Future<List<DispatchModel>> getAll({String? farmId, DateTime? fromDate, DateTime? toDate});

  /// مزامنة السجلات المعلقة
  Future<void> syncPendingRecords();

  /// عدد السجلات المعلقة
  Future<int> getPendingCount();
}