import 'package:core/core.dart';

/// حالة استخدام: حفظ سجل إنتاج البيض
///
/// التحقق من:
/// 1. التاريخ ≤ اليوم (لا يسمح بالمستقبل)
/// 2. الإجمالي > 0
/// 3. مكسور + أرضي ≤ الإجمالي
class SaveEggProductionUseCase {
  final EggProductionRepository repository;

  const SaveEggProductionUseCase(this.repository);

  Future<SaveEggProductionResult> call(EggProductionModel record) async {
    // التحقق من التاريخ
    if (record.date.isAfter(DateTime.now())) {
      return SaveEggProductionResult.failure('لا يمكن اختيار تاريخ مستقبلي');
    }

    // التحقق من الإجمالي
    if (record.totalEggs == 0) {
      return SaveEggProductionResult.failure('الإجمالي لا يمكن أن يكون صفراً');
    }

    // التحقق من كسر/أرضي
    if (record.brokenEggs + record.dirtyEggs > record.totalEggs) {
      return SaveEggProductionResult.failure(
        'مجموع البيض المكسور والأرضي أكبر من الإجمالي',
      );
    }

    try {
      await repository.saveLocal(record);
      return SaveEggProductionResult.success();
    } catch (e) {
      return SaveEggProductionResult.failure('فشل الحفظ: $e');
    }
  }
}

class SaveEggProductionResult {
  final bool success;
  final String? error;

  const SaveEggProductionResult._({required this.success, this.error});

  factory SaveEggProductionResult.success() {
    return const SaveEggProductionResult._(success: true);
  }

  factory SaveEggProductionResult.failure(String error) {
    return SaveEggProductionResult._(success: false, error: error);
  }
}