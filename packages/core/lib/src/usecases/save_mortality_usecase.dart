import 'package:core/core.dart';

/// حالة استخدام: حفظ سجل النفوق
///
/// يتحقق من:
/// 1. نسبة النفوق (تنبيه إذا >= FarmAnalytics.mortalityWarningRate)
/// 2. رفع الصورة إن وجدت
/// 3. حفظ محلياً + مزامنة
///
/// ملاحظة: تم توحيد عتبة التحذير مع FarmAnalytics.mortalityWarningRate
/// (كانت هذه الحالة تستخدم عتبة 1.0% منفصلة بينما تستخدم FarmAnalytics
/// عتبتي 0.10%/0.20%، ما كان يُنتج تصنيفات متضاربة لنفس الحدث).
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
    // حماية من القسمة على صفر (قطيع بدون طيور أو عدد غير مُحلَّى بعد)
    // نستخدم FarmAnalytics.dailyMortalityRate (days: 1) لضمان توحيد
    // منطق حساب نسبة النفوق مع باقي الشاشات (لوحة التحكم والتقارير).
    final mortalityPercentage = FarmAnalytics.dailyMortalityRate(
      totalDeaths: record.count,
      birdCount: flockCount,
      days: 1,
    );

    // نفس عتبات FarmAnalytics المستخدمة في التقارير ولوحة التحكم،
    // بدلاً من عتبة منفصلة (1.0%) كانت تتناقض مع 0.10%/0.20%.
    final highMortalityWarning =
        FarmAnalytics.mortalityLevel(mortalityPercentage) != 'ok';

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