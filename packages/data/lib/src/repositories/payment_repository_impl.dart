import 'package:core/core.dart';
import 'package:domain/domain.dart';
import '../datasources/local/daos/dispatch_dao.dart';
import '../datasources/local/daos/payment_dao.dart';
import '../datasources/remote/supabase_payment_datasource.dart';
import 'package:uuid/uuid.dart';

/// ═══════════════════════════════════════════════
/// تنفيذ مستودع القبض/الدفع - للمدير فقط
/// ═══════════════════════════════════════════════
class PaymentRepositoryImpl implements PaymentRepository {
  final PaymentDao _paymentDao;
  final DispatchDao _dispatchDao;
  final SupabasePaymentDatasource _remoteDatasource;
  final _uuid = const Uuid();

  PaymentRepositoryImpl({
    required PaymentDao paymentDao,
    required DispatchDao dispatchDao,
    required SupabasePaymentDatasource remoteDatasource,
  })  : _paymentDao = paymentDao,
        _dispatchDao = dispatchDao,
        _remoteDatasource = remoteDatasource;

  @override
  Future<void> save(PaymentModel payment) async {
    // ═══ C2+C3 FIX: توليد ID واحد فقط واستخدامه في كلا الموقعين ═══
    final localId = payment.id ?? _uuid.v4();
    final now = DateTime.now();

    if (payment.id == null) {
      final localPayment = payment.copyWith(
        id: localId,
        createdAt: now,
        updatedAt: now,
      );
      await _paymentDao.insert(localPayment);

      try {
        // إرسال نفس ID للخادم (يمنع تكرار السجل عند المزامنة)
        await _remoteDatasource.insert(localPayment);
      } catch (_) {
        // Offline: queued for next sync
      }
    } else {
      final localPayment = payment.copyWith(updatedAt: now);
      await _paymentDao.update(payment.id!, localPayment);
      try {
        await _remoteDatasource.update(payment.id!, localPayment);
      } catch (_) {
        // Offline: queued for next sync
      }
    }

    // Update dispatch payment status
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
