import 'package:core/core.dart';

/// حالة استخدام: حفظ استهلاك العلف
class SaveFeedConsumptionUseCase {
  final FeedRepository repository;

  const SaveFeedConsumptionUseCase(this.repository);

  Future<SaveFeedResult> call(FeedConsumptionModel record) async {
    if (record.date.isAfter(DateTime.now())) {
      return SaveFeedResult.failure('لا يمكن اختيار تاريخ مستقبلي');
    }
    if (record.quantityKg <= 0) {
      return SaveFeedResult.failure('الكمية يجب أن تكون أكبر من صفر');
    }

    try {
      await repository.saveConsumptionLocal(record);
      return SaveFeedResult.success();
    } catch (e) {
      return SaveFeedResult.failure('فشل الحفظ: $e');
    }
  }
}

class SaveFeedResult {
  final bool success;
  final String? error;

  const SaveFeedResult._({required this.success, this.error});

  factory SaveFeedResult.success() {
    return const SaveFeedResult._(success: true);
  }

  factory SaveFeedResult.failure(String error) {
    return SaveFeedResult._(success: false, error: error);
  }
}