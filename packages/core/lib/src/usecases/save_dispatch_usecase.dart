import 'package:core/core.dart';

/// حالة استخدام: حفظ تخريج البيض (بدون أي مبلغ مالي)
class SaveDispatchUseCase {
  final DispatchRepository repository;
  final MedicationRepository medicationRepository;

  const SaveDispatchUseCase(this.repository, this.medicationRepository);

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
      await repository.saveLocal(record);
      return SaveDispatchResult.success();
    } catch (e) {
      return SaveDispatchResult.failure('فشل الحفظ: $e');
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