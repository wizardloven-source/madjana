import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// نتيجة حفظ استهلاك العلف
class FeedSaveResult {
  final bool success;
  final String? error;

  const FeedSaveResult._({required this.success, this.error});

  const FeedSaveResult.success() : this._(success: true);
  const FeedSaveResult.failure(String error)
      : this._(success: false, error: error);
}

/// Provider لاستهلاك العلف
class FeedConsumptionNotifier extends StateNotifier<bool> {
  final FeedRepository _repository;
  final SaveFeedConsumptionUseCase _saveUseCase;

  FeedConsumptionNotifier({
    required FeedRepository repository,
    required SaveFeedConsumptionUseCase saveUseCase,
  })  : _repository = repository,
        _saveUseCase = saveUseCase,
        super(false);

  Future<FeedSaveResult> save(FeedConsumptionModel record) async {
    final result = await _saveUseCase.call(record);
    if (result.success) {
      _repository.syncPendingConsumption();
      return const FeedSaveResult.success();
    }
    return FeedSaveResult.failure(result.error ?? 'فشل الحفظ');
  }

  Future<List<FeedConsumptionModel>> getAll({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) {
    return _repository.getAllConsumption(
      farmId: farmId,
      fromDate: fromDate,
      toDate: toDate,
    );
  }
}

final feedConsumptionProvider =
    StateNotifierProvider<FeedConsumptionNotifier, bool>((ref) {
  return FeedConsumptionNotifier(
    repository: ref.watch(feedRepositoryProvider),
    saveUseCase: SaveFeedConsumptionUseCase(ref.watch(feedRepositoryProvider)),
  );
});