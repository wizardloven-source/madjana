import 'package:core/core.dart';

/// واجهة مستودع العلف (استهلاك + استلام)
abstract class FeedRepository {
  /// حفظ استهلاك علف محلياً
  Future<void> saveConsumptionLocal(FeedConsumptionModel record);

  /// حفظ استلام علف محلياً
  Future<void> saveReceivedLocal(FeedReceivedModel record);

  /// جلب استهلاك اليوم
  Future<List<FeedConsumptionModel>> getTodayConsumption(String farmId);

  /// جلب كل استهلاك العلف
  Future<List<FeedConsumptionModel>> getAllConsumption({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  });

  /// جلب كل شحنات العلف المستلمة
  Future<List<FeedReceivedModel>> getAllReceived({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  });

  /// مزامنة استهلاك العلف المعلق
  Future<void> syncPendingConsumption();

  /// تسجيل سعر كيلوغرام علف مستلم (المدير) — محلياً وسحابياً
  Future<void> setReceivedPrice({
    required String id,
    required double pricePerKg,
  });

  /// حساب مخزون العلف الحالي (مستلم - مستهلك)
  Future<double> getCurrentFeedStock(String farmId);
}