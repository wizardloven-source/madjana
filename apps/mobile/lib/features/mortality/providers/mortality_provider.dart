import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// نتيجة حفظ النفوق
class MortalitySaveResult {
  final bool success;
  final String? error;
  final bool highMortalityWarning;
  final double mortalityPercentage;

  const MortalitySaveResult._({
    required this.success,
    this.error,
    this.highMortalityWarning = false,
    this.mortalityPercentage = 0,
  });

  factory MortalitySaveResult.success({
    bool highMortalityWarning = false,
    double mortalityPercentage = 0,
  }) {
    return MortalitySaveResult._(
      success: true,
      highMortalityWarning: highMortalityWarning,
      mortalityPercentage: mortalityPercentage,
    );
  }

  const MortalitySaveResult.failure(String error)
      : this._(success: false, error: error);
}

/// Provider للنفوق
class MortalityNotifier extends StateNotifier<bool> {
  final MortalityRepository _repository;
  final SaveMortalityUseCase _saveUseCase;

  MortalityNotifier({
    required MortalityRepository repository,
    required SaveMortalityUseCase saveUseCase,
  })  : _repository = repository,
        _saveUseCase = saveUseCase,
        super(false);

  Future<MortalitySaveResult> save(
    MortalityModel record, {
    File? imageFile,
  }) async {
    // رفع الصورة أولاً إن وجدت
    String? imageUrl = record.imageUrl;
    if (imageFile != null) {
      imageUrl = await _repository.uploadImage(imageFile, record.id ?? '');
      record = MortalityModel(
        id: record.id,
        farmId: record.farmId,
        flockId: record.flockId,
        date: record.date,
        count: record.count,
        reason: record.reason,
        reasonOther: record.reasonOther,
        notes: record.notes,
        imageUrl: imageUrl,
        workerId: record.workerId,
      );
    }

    final result = await _saveUseCase.call(record);
    if (result.success) {
      _repository.syncPendingRecords();
      return MortalitySaveResult.success(
        highMortalityWarning: result.highMortalityWarning,
        mortalityPercentage: result.mortalityPercentage,
      );
    }
    return MortalitySaveResult.failure(result.error ?? 'فشل الحفظ');
  }

  Future<List<MortalityModel>> getRecords({
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

final mortalityProvider = StateNotifierProvider<MortalityNotifier, bool>((ref) {
  return MortalityNotifier(
    repository: ref.watch(mortalityRepositoryProvider),
    saveUseCase: SaveMortalityUseCase(ref.watch(mortalityRepositoryProvider)),
  );
});