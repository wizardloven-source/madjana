import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// نتيجة حفظ سجل دوائي
class MedicationSaveResult {
  final bool success;
  final String? error;
  final int withdrawalDays;

  const MedicationSaveResult._({
    required this.success,
    this.error,
    this.withdrawalDays = 0,
  });

  factory MedicationSaveResult.success({int withdrawalDays = 0}) {
    return MedicationSaveResult._(
      success: true,
      withdrawalDays: withdrawalDays,
    );
  }

  const MedicationSaveResult.failure(String error)
      : this._(success: false, error: error);
}

/// Provider للأدوية
class MedicationsNotifier extends StateNotifier<bool> {
  final MedicationRepository _repository;
  final SaveMedicationUseCase _saveUseCase;

  MedicationsNotifier({
    required MedicationRepository repository,
    required SaveMedicationUseCase saveUseCase,
  })  : _repository = repository,
        _saveUseCase = saveUseCase,
        super(false);

  Future<MedicationSaveResult> save({
    required String farmId,
    required DateTime date,
    required MedicationType type,
    required String medicineName,
    required String dosage,
    required AdministrationRoute route,
    int? treatmentDays,
    int withdrawalDays = 0,
    String? notes,
    required String workerId,
  }) async {
    final record = MedicationModel(
      farmId: farmId,
      date: date,
      type: type,
      medicineName: medicineName,
      dosage: dosage,
      administrationRoute: route,
      treatmentDays: treatmentDays,
      withdrawalDays: withdrawalDays,
      notes: notes,
      workerId: workerId,
    );

    final result = await _saveUseCase.call(record);
    if (result.success) {
      _repository.syncPendingRecords();
      return MedicationSaveResult.success(withdrawalDays: result.withdrawalDays);
    }
    return MedicationSaveResult.failure(result.error ?? 'فشل الحفظ');
  }

  Future<List<MedicationModel>> getAll({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) {
    return _repository.getAll(
      farmId: farmId,
      fromDate: fromDate,
      toDate: toDate,
    );
  }
}

final medicationsProvider = StateNotifierProvider<MedicationsNotifier, bool>((ref) {
  return MedicationsNotifier(
    repository: ref.watch(medicationRepositoryProvider),
    saveUseCase: SaveMedicationUseCase(ref.watch(medicationRepositoryProvider)),
  );
});