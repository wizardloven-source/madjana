import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// ═══════════════════════════════════════════
/// البيانات المرجعية (قطعان، زبائن، أدوية)
/// ═══════════════════════════════════════════

/// جلب القطعان النشطة للمدجنة
final flocksProvider = FutureProvider.family<List<FlockModel>, String>((ref, farmId) async {
  return ref.read(flockDaoProvider).getByFarm(farmId);
});

/// جلب الزبائن للمدجنة
final customersProvider = FutureProvider.family<List<CustomerModel>, String>((ref, farmId) async {
  return ref.read(dispatchRepositoryProvider).getCustomers(farmId);
});

/// جلب كتالوج الأدوية
final medicinesCatalogProvider = FutureProvider<List<MedicineModel>>((ref) async {
  return ref.read(medicationRepositoryProvider).getMedicinesCatalog();
});

/// حالة تحميل البيانات المرجعية
final referenceDataReadyProvider = FutureProvider.autoDispose<void>((ref) async {
  return;
});
