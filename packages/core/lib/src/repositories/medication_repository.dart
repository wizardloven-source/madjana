import 'package:core/core.dart';

/// واجهة مستودع الأدوية
abstract class MedicationRepository {
  /// حفظ سجل دوائي محلياً
  Future<void> saveLocal(MedicationModel record);

  /// جلب كتالوج الأدوية
  Future<List<MedicineModel>> getMedicinesCatalog();

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