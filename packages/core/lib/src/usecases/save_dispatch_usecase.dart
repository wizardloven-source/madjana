import 'package:core/core.dart';

/// حالة استخدام: حفظ تخريج البيض (بدون أي مبلغ مالي) + إنشاء فاتورته
///
/// لماذا يُنشأ سجل الفاتورة هنا لا عند القبض:
///   كل تقارير الإيراد والربحية والمقبوضات تقرأ جدول `payments`. لو لم
///   يوجد سجل لتخريج، اختفى من كل تلك التقارير — أي مخريج لم يُقبَض بعد
///   كان يُحذف من الربحية. العامل لا يعرف السعر، لذلك الفاتورة تُفتح
///   بقيمة صفر وتُسعَّر عند السداد من شاشة القبض.
class SaveDispatchUseCase {
  final DispatchRepository repository;
  final MedicationRepository medicationRepository;
  final PaymentRepository? paymentRepository;

  const SaveDispatchUseCase(
    this.repository,
    this.medicationRepository, [
    this.paymentRepository,
  ]);

  Future<SaveDispatchResult> call(DispatchModel record) async {
    if (record.date.isAfter(DateTime.now())) {
      return SaveDispatchResult.failure('لا يمكن اختيار تاريخ مستقبلي');
    }
    if (record.totalEggs == 0) {
      return SaveDispatchResult.failure('الكمية يجب أن تكون أكبر من صفر');
    }

    // P0-03: Check withdrawal period before dispatching eggs
    final withdrawalCheck = await _checkWithdrawalPeriod(record);
    if (withdrawalCheck != null) {
      return SaveDispatchResult.failure(withdrawalCheck);
    }

    try {
      final dispatchId = await repository.saveLocal(record);
      await _openInvoice(dispatchId, record);
      return SaveDispatchResult.success();
    } catch (e) {
      return SaveDispatchResult.failure('فشل الحفظ: $e');
    }
  }

  /// يفتح فاتورة بقيمة صفر مرتبطة بالتخريج.
  ///
  /// قيمة صفر لا قيمة عشوائية: `FinancialKpi` و`FlockProfitability` يأخذان
  /// أقصى `totalDue` لكل فاتورة، فصفر = لا يساهم في الإيراد ولا يُنشئ
  /// تضخيماً، بينما يبقى التخريج ظاهراً في "غير المسدَّد".
  ///
  /// `manager_id` NOT NULL في الخادم ⇒ نمرّر `workerId` (مستخدم صالح في
  /// `users`) ويُستبدل به المدير عند التسديد.
  ///
  /// الفشل هنا لا يُسقط التخريج: التخريج حُفظ بالفعل، والفاتورة ستُفتح
  /// عند أول تسديد من شاشة القبض.
  Future<void> _openInvoice(String dispatchId, DispatchModel record) async {
    final payments = paymentRepository;
    if (payments == null) return;
    try {
      final existing = await payments.getForDispatch(dispatchId);
      if (existing.isNotEmpty) return;
      await payments.save(
        PaymentModel(
          farmId: record.farmId,
          dispatchId: dispatchId,
          customerId: record.customerId,
          date: record.date,
          pricePerCarton: 0,
          totalDue: 0,
          amountPaid: 0,
          paymentMethod: PaymentMethod.credit,
          notes: 'فاتورة تلقائية - بانتظار التسعير',
          managerId: record.workerId,
        ),
      );
    } catch (_) {
      // best-effort: لا نمنع حفظ التخريج
    }
  }

  /// P0-03: Check if any recent medication on this flock has withdrawal period active
  Future<String?> _checkWithdrawalPeriod(DispatchModel record) async {
    try {
      final medications = await medicationRepository.getAll(
        farmId: record.farmId,
      );

      final now = DateTime.now();
      for (final med in medications) {
        if (med.flockId == record.flockId &&
            med.withdrawalDays != null && med.withdrawalDays! > 0) {
          final medicationDate = med.date;
          final withdrawalEndDate =
              medicationDate.add(Duration(days: med.withdrawalDays!));
          if (now.isBefore(withdrawalEndDate)) {
            final daysRemaining =
                withdrawalEndDate.difference(now).inDays;
            return 'فترة سحب الدواء "${med.medicineName}" لم تنته بعد '
                '(${daysRemaining} يوم متبقي). '
                'لا يمكن بيع البيض حتى ${withdrawalEndDate.day}/${withdrawalEndDate.month}/${withdrawalEndDate.year}';
          }
        }
      }
      return null;
    } catch (e) {
      // If we can't check medications, allow the dispatch (best-effort)
      return null;
    }
  }
}

class SaveDispatchResult {
  final bool success;
  final String? error;

  const SaveDispatchResult._({required this.success, this.error});

  factory SaveDispatchResult.success() {
    return const SaveDispatchResult._(success: true);
  }

  factory SaveDispatchResult.failure(String error) {
    return SaveDispatchResult._(success: false, error: error);
  }
}