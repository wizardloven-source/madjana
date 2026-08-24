import 'package:core/core.dart';

/// واجهة مستودع القبض/الدفع - للمدير فقط
abstract class PaymentRepository {
  /// تسجيل قبض/دفع
  Future<void> save(PaymentModel payment);

  /// تحديث حالة دفع فاتورة التخريج
  Future<void> updateDispatchPaymentStatus(String dispatchId, PaymentStatus status);

  /// جلب كل المدفوعات
  Future<List<PaymentModel>> getAll({String? farmId, DateTime? fromDate, DateTime? toDate});

  /// إجمالي المستحق وغير المسدد
  Future<double> getTotalOutstanding({String? farmId});

  /// إجمالي المحصل (المقبوضات)
  Future<double> getTotalCollected({String? farmId, DateTime? fromDate, DateTime? toDate});
}