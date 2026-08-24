import 'package:core/core.dart';
import 'package:domain/domain.dart';
import '../datasources/local/daos/dispatch_dao.dart';
import '../datasources/local/daos/payment_dao.dart';

/// تنفيذ مستودع القبض/الدفع - للمدير فقط
class PaymentRepositoryImpl implements PaymentRepository {
  final PaymentDao _paymentDao;
  final DispatchDao _dispatchDao;

  PaymentRepositoryImpl({
    required PaymentDao paymentDao,
    required DispatchDao dispatchDao,
  })  : _paymentDao = paymentDao,
        _dispatchDao = dispatchDao;

  @override
  Future<void> save(PaymentModel payment) async {
    await _paymentDao.insert(payment);

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
  }) {
    return _paymentDao.getAll(farmId: farmId, fromDate: fromDate, toDate: toDate);
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