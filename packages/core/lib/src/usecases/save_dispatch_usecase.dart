import 'package:core/core.dart';

/// حالة استخدام: حفظ تخريج البيض (بدون أي مبلغ مالي)
class SaveDispatchUseCase {
  final DispatchRepository repository;

  const SaveDispatchUseCase(this.repository);

  Future<SaveDispatchResult> call(DispatchModel record) async {
    if (record.date.isAfter(DateTime.now())) {
      return SaveDispatchResult.failure('لا يمكن اختيار تاريخ مستقبلي');
    }
    if (record.totalEggs == 0) {
      return SaveDispatchResult.failure('الكمية يجب أن تكون أكبر من صفر');
    }

    try {
      await repository.saveLocal(record);
      return SaveDispatchResult.success();
    } catch (e) {
      return SaveDispatchResult.failure('فشل الحفظ: $e');
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