import 'package:core/core.dart';

/// واجهة مستودع الأدوية
abstract class MedicationRepository {
  /// حفظ سجل دوائي محلياً
  Future<void> saveLocal(MedicationModel record);

  /// جلب كتالوج الأدوية
  Future<List<MedicineModel>> getMedicinesCatalog();

  /// حفظ/تحديث دواء في الكتالوج
  Future<void> saveMedicine(MedicineModel medicine);

  /// حذف دواء من الكتالوج
  Future<void> deleteMedicine(String id);

  /// جلب كل السجلات الدوائية
  Future<List<MedicationModel>> getAll({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  });

  /// مزامنة السجلات المعلقة
  Future<void> syncPendingRecords();

  /// عدد السجلات المعلقة
  Future<int> getPendingCount();
}