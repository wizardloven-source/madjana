import 'package:core/core.dart';
import 'package:domain/domain.dart';
import '../datasources/local/daos/dispatch_dao.dart';
import '../datasources/local/daos/payment_dao.dart';
import '../datasources/remote/supabase_payment_datasource.dart';

/// ═══════════════════════════════════════════════
/// تنفيذ مستودع القبض/الدفع - للمدير فقط
/// ═══════════════════════════════════════════════
class PaymentRepositoryImpl implements PaymentRepository {
  final PaymentDao _paymentDao;
  final DispatchDao _dispatchDao;
  final SupabasePaymentDatasource _remoteDatasource;

  PaymentRepositoryImpl({
    required PaymentDao paymentDao,
    required DispatchDao dispatchDao,
    required SupabasePaymentDatasource remoteDatasource,
  })  : _paymentDao = paymentDao,
        _dispatchDao = dispatchDao,
        _remoteDatasource = remoteDatasource;

  @override
  Future<void> save(PaymentModel payment) async {
    // حفظ محلي أولاً (offline-first)
    await _paymentDao.insert(payment);

    try {
      // مزامنة مع السحابة
      if (payment.id != null) {
        await _remoteDatasource.update(payment.id!, payment);
      } else {
        await _remoteDatasource.insert(payment);
      }
    } catch (_) {
      // غير متصل: تم الحفظ محلياً، ستُزامَن لاحقاً
    }

    // تحديث حالة فاتورة التخريج
    final dispatchId = payment.dispatchId;
    if (dispatchId != null) {
      await _dispatchDao.updatePaymentStatus(
        dispatchId,
        payment.isPaid ? PaymentStatus.paid : PaymentStatus.partial,
      );
    }
  }

  @override
  Future<void> updateDispatchPaymentStatus(
    String dispatchId,
    PaymentStatus status,
  ) async {
    await _dispatchDao.updatePaymentStatus(dispatchId, status);
  }

  @override
  Future<List<PaymentModel>> getAll({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    try {
      final payments = await _remoteDatasource.getPayments(
        farmId: farmId ?? '',
        fromDate: fromDate,
        toDate: toDate,
      );
      return payments;
    } catch (_) {
      return _paymentDao.getAll(
        farmId: farmId,
        fromDate: fromDate,
        toDate: toDate,
      );
    }
  }

  @override
  Future<double> getTotalOutstanding({String? farmId}) {
    return _paymentDao.getTotalOutstanding(farmId: farmId);
  }

  @override
  Future<double> getTotalCollected({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) {
    return _paymentDao.getTotalCollected(
      farmId: farmId,
      fromDate: fromDate,
      toDate: toDate,
    );
  }
}
