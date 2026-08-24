/// حسابات تحليلية جوهرية للمدجنة
///
/// - معدل الإنتاج % (أهم مؤشر أداء لمداجن البياض)
/// - معدل النفوق اليومي % مع حدود الإنذار
/// - تنبؤ نفاد العلف بالأيام
class FarmAnalytics {
  FarmAnalytics._();

  /// حد التحذير لمعدل النفوق اليومي (%)
  static const double mortalityWarningRate = 0.10;

  /// حد الخطر لمعدل النفوق اليومي (%)
  static const double mortalityDangerRate = 0.20;

  /// عدد الأيام التي تحتها يصبح تنبؤ العلف خطراً
  static const double feedDangerDays = 3;

  /// عدد الأيام التي تحتها يصبح تنبؤ العلف تحذيراً
  static const double feedWarningDays = 7;

  /// معدل الإنتاج اليومي %
  ///
  /// [eggs] بيض يوم واحد، [birdCount] الطيور الحية
  /// مثال: 1000 طائر أنتجت 900 بيضة => 90%
  static double productionRate({
    required int eggs,
    required int birdCount,
  }) {
    if (birdCount <= 0 || eggs <= 0) return 0;
    return eggs / birdCount * 100;
  }

  /// متوسط معدل الإنتاج لفترة %
  ///
  /// [totalEggs] مجموع البيض، [days] عدد الأيام
  static double avgProductionRate({
    required int totalEggs,
    required int birdCount,
    required int days,
  }) {
    if (birdCount <= 0 || days <= 0 || totalEggs <= 0) return 0;
    return totalEggs / (birdCount * days) * 100;
  }

  /// معدل النفوق اليومي % لفترة
  ///
  /// مثال: 3 طيور نفقت من 1000 خلال يوم واحد => 0.3% (خطر)
  static double dailyMortalityRate({
    required int totalDeaths,
    required int birdCount,
    required int days,
  }) {
    if (birdCount <= 0 || days <= 0) return 0;
    return totalDeaths / (birdCount * days) * 100;
  }

  /// تصنيف حالة معدل النفوق: ok | warning | danger
  static String mortalityLevel(double dailyRatePercent) {
    if (dailyRatePercent >= mortalityDangerRate) return 'danger';
    if (dailyRatePercent >= mortalityWarningRate) return 'warning';
    return 'ok';
  }

  /// عدد الأيام المتوقعة حتى نفاد العلف
  ///
  /// يعيد null إذا لا يوجد استهلاك (لا يمكن التقدير)
  static double? feedDaysLeft({
    required double stockKg,
    required double avgDailyConsumptionKg,
  }) {
    if (avgDailyConsumptionKg <= 0 || stockKg < 0) return null;
    return stockKg / avgDailyConsumptionKg;
  }

  /// تصنيف حالة العلف: ok | warning | danger | unknown
  static String feedLevel(double? daysLeft) {
    if (daysLeft == null) return 'unknown';
    if (daysLeft <= feedDangerDays) return 'danger';
    if (daysLeft <= feedWarningDays) return 'warning';
    return 'ok';
  }
}
