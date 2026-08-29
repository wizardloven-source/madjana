import '../models/opening_balance_model.dart';

/// مستودع الأرصدة الافتتاحية للقطعان القديمة
abstract class OpeningBalanceRepository {
  /// جلب رصيد قطيع (إن وُجد)
  Future<OpeningBalanceModel?> getForFlock(String farmId, String flockId);

  /// جلب كل الأرصدة للمزرعة
  Future<List<OpeningBalanceModel>> getForFarm(String farmId);

  /// حفظ رصيد قطيع (تحديث إن وُجد)
  Future<void> save(OpeningBalanceModel balance);

  /// حذف رصيد قطيع
  Future<void> delete(String farmId, String flockId);
}