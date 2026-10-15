import '../models/profit_distribution_preview.dart';

/// الشراكة (W7.2/W7.3) — مبنية على دوال M24/M30 وRLS على الجداول.
///
/// * `calculateDistribution` **قراءة فقط**: الدالة
///   `calculate_profit_distribution` تُعاين التوزيع ولا تكتب شيئاً.
/// * `createDistribution`/`approveDistribution` (M30) تُخزّن المعاينة في
///   `profit_distributions`/`profit_distribution_details` ثم تعتمدها. تفاصيل
///   المحرّك وقيد الاحتياطي في `docs/PARTNERS.md` §2.6.
///
/// كل الأخطاء المُتحقَّق منها تُرمى كـ [SyncFailure] بكود ثابت (مثل
/// `AUTHORIZATION_DENIED`) بدل نصّ PostgREST عام.
abstract class PartnershipRepository {
  /// معاينة حصص الشركاء من صافي ربح مدجنة خلال فترة (اختياري: قطيع بعينه).
  ///
  /// ترفع القاعدة `AUTHORIZATION_DENIED` إن لم يكن المُتصل مدير المدجنة أو
  /// مدير نظام، و`INVALID_PERCENTAGES` إذا تجاوز مجموع النسب 100،
  /// و`FARM_NOT_FOUND`/`FLOCK_NOT_FOUND`/`FLOCK_FARM_MISMATCH` عند أخطاء المدخلات.
  Future<List<ProfitDistributionPreview>> calculateDistribution({
    required String farmId,
    required DateTime periodStart,
    required DateTime periodEnd,
    String? flockId,
  });

  /// يُخزّن توزيعاً جديداً (رأس `draft` + بنود `pending`) ويعيد معرّفه.
  ///
  /// الأخطاء: `AUTHORIZATION_DENIED` إن لم يكن المُتصل مدير المدجنة أو مدير
  /// نظام، `DISTRIBUTION_EXISTS` عند تكرار (المزرعة/القطيع/الفترة)،
  /// `NEGATIVE_NET_PROFIT` إن كانت الفترة خاسرة، `INVALID_RESERVE` لأساس سالب،
  /// و`INVALID_PERIOD`/`FARM_NOT_FOUND`/`FLOCK_NOT_FOUND`/`FLOCK_FARM_MISMATCH`
  /// لأخطاء المدخلات. `reserveAmount` افتراضه 0 — إبقاؤه 0 يضمن
  /// `distributable_profit == SUM(amount)` (راجع قيد الاحتياطي في docs).
  Future<String> createDistribution({
    required String farmId,
    required DateTime periodStart,
    required DateTime periodEnd,
    String? flockId,
    double reserveAmount = 0,
    String? label,
    String? notes,
  });

  /// يعتمد توزيعاً `draft` (مدير النظام فقط) فيصبح `approved`.
  ///
  /// ترفع `AUTHORIZATION_DENIED` لغير مدير النظام،
  /// `DISTRIBUTION_NOT_FOUND` إن لم يوجد، و`INVALID_STATUS_TRANSITION` إن لم
  /// تكن حالته `draft`.
  Future<void> approveDistribution({required String distributionId});
}
