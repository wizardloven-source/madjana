import 'package:core/core.dart';

/// حالة استخدام: حفظ سجل النفوق
/// 
/// يتحقق من:
/// 1. نسبة النفوق (تنبيه إذا > 1%)
/// 2. رفع الصورة إن وجدت
/// 3. حفظ محلياً + مزامنة
class SaveMortalityUseCase {
  final MortalityRepository repository;

  const SaveMortalityUseCase(this.repository);

  Future<SaveMortalityResult> call(MortalityModel record) async {
    // 1. التحقق من التاريخ
    if (record.date.isAfter(DateTime.now())) {
      return SaveMortalityResult.failure('تاريخ غير صالح');
    }

    // 2. التحقق من السبب
    if (record.reason == MortalityReason.other && 
        (record.reasonOther == null || record.reasonOther!.isEmpty)) {
      return SaveMortalityResult.failure('يجب تحديد السبب');
    }

    // 3. جلب العدد الحالي للقطيع للتحذير
    final flockCount = await repository.getFlockCurrentCount(record.flockId);
    final mortalityPercentage = (record.count / flockCount) * 100;
    
    bool highMortalityWarning = false;
    if (mortalityPercentage > 1.0) {
      highMortalityWarning = true;
    }

    // 4. حفظ
    try {
      await repository.saveLocal(record);
      return SaveMortalityResult.success(
        highMortalityWarning: highMortalityWarning,
        mortalityPercentage: mortalityPercentage,
      );
    } catch (e) {
      return SaveMortalityResult.failure('فشل الحفظ: $e');
    }
  }
}

class SaveMortalityResult {
  final bool success;
  final String? error;
  final bool highMortalityWarning;
  final double mortalityPercentage;

  const SaveMortalityResult._({
    required this.success,
    this.error,
    this.highMortalityWarning = false,
    this.mortalityPercentage = 0,
  });

  factory SaveMortalityResult.success({
    bool highMortalityWarning = false,
    double mortalityPercentage = 0,
  }) {
    return SaveMortalityResult._(
      success: true,
      highMortalityWarning: highMortalityWarning,
      mortalityPercentage: mortalityPercentage,
    );
  }

  factory SaveMortalityResult.failure(String error) {
    return SaveMortalityResult._(success: false, error: error);
  }
}