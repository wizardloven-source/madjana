import 'package:core/core.dart';

/// حالة استخدام: حفظ سجل دوائي مع تنبيه فترة السحب
class SaveMedicationUseCase {
  final MedicationRepository repository;

  const SaveMedicationUseCase(this.repository);

  Future<SaveMedicationResult> call(MedicationModel record) async {
    if (record.date.isAfter(DateTime.now())) {
      return SaveMedicationResult.failure('لا يمكن اختيار تاريخ مستقبلي');
    }

    try {
      await repository.saveLocal(record);
      return SaveMedicationResult.success(
        withdrawalDays: record.withdrawalDays,
      );
    } catch (e) {
      return SaveMedicationResult.failure('فشل الحفظ: $e');
    }
  }
}

class SaveMedicationResult {
  final bool success;
  final String? error;
  final int withdrawalDays;

  const SaveMedicationResult._({
    required this.success,
    this.error,
    this.withdrawalDays = 0,
  });

  factory SaveMedicationResult.success({int withdrawalDays = 0}) {
    return SaveMedicationResult._(
      success: true,
      withdrawalDays: withdrawalDays,
    );
  }

  factory SaveMedicationResult.failure(String error) {
    return SaveMedicationResult._(success: false, error: error);
  }
}