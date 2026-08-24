import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// نتيجة حفظ استلام العلف
class FeedReceivedSaveResult {
  final bool success;
  final String? error;

  const FeedReceivedSaveResult._({required this.success, this.error});

  const FeedReceivedSaveResult.success() : this._(success: true);
  const FeedReceivedSaveResult.failure(String error)
      : this._(success: false, error: error);
}

/// Provider لاستلام العلف
class FeedReceivedNotifier extends StateNotifier<bool> {
  final FeedRepository _repository;

  FeedReceivedNotifier({required FeedRepository repository})
      : _repository = repository,
        super(false);

  Future<FeedReceivedSaveResult> save({
    required String farmId,
    required DateTime date,
    required FeedEntryMode entryMode,
    required double quantity,
    required double quantityKg,
    required FeedType feedType,
    String? supplier,
    String? invoiceNumber,
    String? notes,
  }) async {
    try {
      await _repository.saveReceivedLocal(
        FeedReceivedModel(
          farmId: farmId,
          date: date,
          entryMode: entryMode,
          quantity: quantity,
          quantityKg: quantityKg,
          feedType: feedType,
          supplier: supplier,
          invoiceNumber: invoiceNumber,
          notes: notes,
        ),
      );
      _repository.syncPendingConsumption();
      return const FeedReceivedSaveResult.success();
    } catch (e) {
      return FeedReceivedSaveResult.failure('فشل الحفظ: $e');
    }
  }

  Future<List<FeedReceivedModel>> getAll({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) {
    return _repository.getAllReceived(
      farmId: farmId,
      fromDate: fromDate,
      toDate: toDate,
    );
  }
}

final feedReceivedProvider =
    StateNotifierProvider<FeedReceivedNotifier, bool>((ref) {
  return FeedReceivedNotifier(repository: ref.watch(feedRepositoryProvider));
});