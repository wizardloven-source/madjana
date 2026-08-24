import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

/// ═══════════════════════════════════════════
/// البيانات المرجعية (قطعان، زبائن، أدوية)
/// ═══════════════════════════════════════════

/// بذر بيانات تجريبية عند أول استخدام (Offline)
Future<void> seedReferenceData(Ref ref, String farmId) async {
  final flockDao = ref.read(flockDaoProvider);

  // بذر القطعان إذا كانت فارغة
  final existingFlocks = await flockDao.getAll();
  if (existingFlocks.isEmpty) {
    await flockDao.saveAll([
      FlockModel(
        id: 'flock-1',
        farmId: farmId,
        breed: 'هايسكس براون',
        startDate: DateTime.now().subtract(const Duration(days: 180)),
        initialCount: 5000,
        currentCount: 4850,
      ),
      FlockModel(
        id: 'flock-2',
        farmId: farmId,
        breed: 'لوهمان',
        startDate: DateTime.now().subtract(const Duration(days: 90)),
        initialCount: 3000,
        currentCount: 2950,
      ),
    ]);
  }

  // بذر الزبائن إذا كانت فارغة
  final customerDao = ref.read(customerDaoProvider);
  final existingCustomers = await customerDao.getByFarm(farmId);
  if (existingCustomers.isEmpty) {
    await customerDao.insert(
      CustomerModel(
        farmId: farmId,
        name: 'مشتري الجملة - أبو علي',
        phone: '07700000001',
        notes: 'زبون دائم',
      ),
    );
    await customerDao.insert(
      CustomerModel(
        farmId: farmId,
        name: 'مشتري التجزئة - أبو أحمد',
        phone: '07700000002',
      ),
    );
    await customerDao.insert(
      CustomerModel(
        farmId: farmId,
        name: 'شركة البيض الوطنية',
        phone: '07700000003',
        notes: 'عقد شهري',
      ),
    );
  }
}

/// جلب القطعان النشطة للمدجنة
final flocksProvider = FutureProvider.family<List<FlockModel>, String>((ref, farmId) async {
  await seedReferenceData(ref, farmId);
  return ref.read(flockDaoProvider).getByFarm(farmId);
});

/// جلب الزبائن للمدجنة
final customersProvider = FutureProvider.family<List<CustomerModel>, String>((ref, farmId) async {
  await seedReferenceData(ref, farmId);
  return ref.read(dispatchRepositoryProvider).getCustomers(farmId);
});

/// جلب كتالوج الأدوية
final medicinesCatalogProvider = FutureProvider<List<MedicineModel>>((ref) async {
  return ref.read(medicationRepositoryProvider).getMedicinesCatalog();
});

/// حالة تحميل البيانات المرجعية
final referenceDataReadyProvider = FutureProvider.autoDispose<void>((ref) async {
  final user = ref.watch(authProvider).currentUser;
  if (user?.farmId != null) {
    await seedReferenceData(ref, user!.farmId!);
  }
});