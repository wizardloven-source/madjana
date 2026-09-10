import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// ═══════════════════════════════════════════
/// البيانات المرجعية (قطعان، زبائن، أدوية)
/// ═══════════════════════════════════════════

/// جلب القطعان النشطة للمدجنة (من السحابة أولاً مع كاش محلي احتياطي)
final flocksProvider = FutureProvider.family<List<FlockModel>, String>((ref, farmId) async {
  return ref.read(flockRepositoryProvider).getFlocks(farmId);
});

/// جلب الزبائن للمدجنة
final customersProvider = FutureProvider.family<List<CustomerModel>, String>((ref, farmId) async {
  return ref.read(dispatchRepositoryProvider).getCustomers(farmId);
});

/// إعدادات المدجنة (المصدر: إعدادات سطح مكتب المدير)
final farmSettingsProvider =
    FutureProvider.family<FarmModel, String>((ref, farmId) async {
  return ref.read(farmRepositoryProvider).getFarm(farmId);
});

/// جلب كتالوج الأدوية
final medicinesCatalogProvider = FutureProvider<List<MedicineModel>>((ref) async {
  return ref.read(medicationRepositoryProvider).getMedicinesCatalog();
});

/// حالة تحميل البيانات المرجعية
final referenceDataReadyProvider = FutureProvider.autoDispose<void>((ref) async {
  return;
});
