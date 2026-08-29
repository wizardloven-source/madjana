import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// حالة حفظ إنتاج البيض
class EggProductionSaveResult {
  final bool success;
  final String? error;

  const EggProductionSaveResult._({required this.success, this.error});

  const EggProductionSaveResult.success() : this._(success: true);
  const EggProductionSaveResult.failure(String error)
      : this._(success: false, error: error);
}

/// Provider لإنتاج البيض
class EggProductionNotifier extends StateNotifier<bool> {
  final EggProductionRepository _repository;
  final SaveEggProductionUseCase _saveUseCase;

  EggProductionNotifier({
    required EggProductionRepository repository,
    required SaveEggProductionUseCase saveUseCase,
  })  : _repository = repository,
        _saveUseCase = saveUseCase,
        super(false);

  Future<EggProductionSaveResult> save(EggProductionModel record) async {
    final result = await _saveUseCase.call(record);
    if (result.success) {
      // مزامنة فورية بعد الحفظ
      _repository.syncPendingRecords();
      return const EggProductionSaveResult.success();
    }
    return EggProductionSaveResult.failure(result.error ?? 'فشل الحفظ');
  }

  /// جلب سجل ليوم أمس (زر "نسخ من أمس")
  Future<EggProductionModel?> getRecordByDate(String farmId, DateTime date) {
    return _repository.getRecordByDate(farmId, date);
  }

  Future<List<EggProductionModel>> getRecords({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) {
    return _repository.getAllRecords(
      farmId: farmId,
      fromDate: fromDate,
      toDate: toDate,
    );
  }

  Future<void> deleteRecord(String id) {
    return _repository.deleteRecord(id);
  }
}

final eggProductionProvider =
    StateNotifierProvider<EggProductionNotifier, bool>((ref) {
  return EggProductionNotifier(
    repository: ref.watch(eggProductionRepositoryProvider),
    saveUseCase: SaveEggProductionUseCase(ref.watch(eggProductionRepositoryProvider)),
  );
});