import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// نتيجة حفظ التخريج
class DispatchSaveResult {
  final bool success;
  final String? error;

  const DispatchSaveResult._({required this.success, this.error});

  const DispatchSaveResult.success() : this._(success: true);
  const DispatchSaveResult.failure(String error)
      : this._(success: false, error: error);
}

/// Provider للتخريج
class DispatchNotifier extends StateNotifier<bool> {
  final DispatchRepository _repository;
  final SaveDispatchUseCase _saveUseCase;

  DispatchNotifier({
    required DispatchRepository repository,
    required SaveDispatchUseCase saveUseCase,
  })  : _repository = repository,
        _saveUseCase = saveUseCase,
        super(false);

  Future<DispatchSaveResult> save({
    required String farmId,
    required DateTime date,
    required String customerId,
    required int cartons,
    required int trays,
    double? trayWeightKg,
    String? notes,
    required String workerId,
  }) async {
    final record = DispatchModel(
      farmId: farmId,
      date: date,
      customerId: customerId,
      cartons: cartons,
      trays: trays,
      trayWeightKg: trayWeightKg,
      notes: notes,
      workerId: workerId,
    );

    final result = await _saveUseCase.call(record);
    if (result.success) {
      _repository.syncPendingRecords();
      return const DispatchSaveResult.success();
    }
    return DispatchSaveResult.failure(result.error ?? 'فشل الحفظ');
  }

  /// إضافة زبون جديد
  Future<String?> addNewCustomer({
    required String farmId,
    required String name,
    required String phone,
    String? notes,
  }) async {
    try {
      return await _repository.addCustomer(
        CustomerModel(
          farmId: farmId,
          name: name,
          phone: phone,
          notes: notes,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<DispatchModel>> getAll({
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

final dispatchProvider = StateNotifierProvider<DispatchNotifier, bool>((ref) {
  return DispatchNotifier(
    repository: ref.watch(dispatchRepositoryProvider),
    saveUseCase: SaveDispatchUseCase(ref.watch(dispatchRepositoryProvider)),
  );
});