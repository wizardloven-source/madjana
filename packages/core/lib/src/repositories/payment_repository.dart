import 'package:core/core.dart';

/// واجهة مستودع القبض/الدفع - للمدير فقط
abstract class PaymentRepository {
  /// تسجيل قبض/دفع
  Future<void> save(PaymentModel payment);

  /// تحديث حالة دفع فاتورة التخريج
  Future<void> updateDispatchPaymentStatus(String dispatchId, PaymentStatus status);

  /// جلب كل المدفوعات
  Future<List<PaymentModel>> getAll({String? farmId, DateTime? fromDate, DateTime? toDate});

  /// جلب مدفوعات فاتورة تخريج واحدة
  Future<List<PaymentModel>> getForDispatch(String dispatchId);

  /// تعديل بنود الفاتورة (السعر/الإجمالي/العملة/سعر الصرف) لكل سجلات القبض
  /// المرتبطة بالتخريج — يُحدّث السجلات الموجودة بدل إضافة سجل جديد،
  /// حتى ينعكس الفرق (زيادة/خصم) على ذمة الزبون مباشرة.
  Future<void> updateInvoiceForDispatch({
    required String dispatchId,
    required double pricePerCarton,
    required double totalDue,
    required AppCurrency currency,
    double? exchangeRate,
  });

  /// إجمالي المستحق وغير المسدد
  Future<double> getTotalOutstanding({String? farmId});

  /// إجمالي المحصل (المقبوضات)
  Future<double> getTotalCollected({String? farmId, DateTime? fromDate, DateTime? toDate});
}