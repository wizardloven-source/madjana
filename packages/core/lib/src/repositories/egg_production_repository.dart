import 'package:core/core.dart';

/// واجهة مستودع إنتاج البيض (Abstract)
abstract class EggProductionRepository {
  /// حفظ سجل محلياً (Offline-first)
  Future<void> saveLocal(EggProductionModel record);

  /// جلب سجلات اليوم
  Future<List<EggProductionModel>> getTodayRecords(String farmId);

  /// جلب سجل تاريخ معين (لزر "نسخ من أمس")
  Future<EggProductionModel?> getRecordByDate(String farmId, DateTime date);

  /// مزامنة السجلات المعلقة مع السحابة
  Future<void> syncPendingRecords();

  /// جلب كل السجلات (للتقارير)
  Future<List<EggProductionModel>> getAllRecords({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  });
}