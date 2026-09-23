import 'package:core/core.dart';
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
      // مدفوعة فقط عندما يساوي إجمالي المدفوعات التراكمي للفاتورة كامل المستحق؛
      // الدفعات الجزئية تبقى partial حتى اكتمالها (لا يعتمد على سجل الدفع الواحد).
      final cumulativePaid = await _paymentDao.getTotalPaidForDispatch(dispatchId);
      final isNowPaid =
          cumulativePaid >= payment.totalDue - 0.001 && payment.totalDue > 0;
      await _dispatchDao.updatePaymentStatus(
        dispatchId,
        isNowPaid ? PaymentStatus.paid : PaymentStatus.partial,
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
    // دمج السجلات المحلية (المعلّقة للمزامنة) مع البعيدة حتى لا تختفي
    // المقبوضات المسجلة دون اتصال أو التي لم تُرفع بعد، مع تفضيل
    // النسخة البعيدة عند التطابق.
    final local = await _paymentDao.getAll(
      farmId: farmId,
      fromDate: fromDate,
      toDate: toDate,
    );
    try {
      final remote = await _remoteDatasource.getPayments(
        farmId: farmId ?? '',
        fromDate: fromDate,
        toDate: toDate,
      );
      final byId = <String, PaymentModel>{
        for (final p in remote)
          if (p.id != null) p.id! : p,
      };
      for (final p in local) {
        if (p.id != null) byId.putIfAbsent(p.id!, () => p);
      }
      return byId.values.toList()
        ..sort((a, b) => b.date.compareTo(a.date));
    } catch (_) {
      return local;
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
