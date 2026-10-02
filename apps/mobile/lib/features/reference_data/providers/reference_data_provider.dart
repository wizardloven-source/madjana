import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// ═══════════════════════════════════════════
/// البيانات المرجعية (قطعان، زبائن، أدوية)
/// ═══════════════════════════════════════════

/// جلب القطعان النشطة للمدجنة (من السحابة أولاً مع كاش محلي احتياطي)
final flocksProvider = FutureProvider.family<List<FlockModel>, String>((
  ref,
  farmId,
) async {
  return ref.read(flockRepositoryProvider).getFlocks(farmId);
});

/// جلب الزبائن للمدجنة
final customersProvider = FutureProvider.family<List<CustomerModel>, String>((
  ref,
  farmId,
) async {
  return ref.read(dispatchRepositoryProvider).getCustomers(farmId);
});

/// إعدادات المدجنة (المصدر: إعدادات سطح مكتب المدير).
///
/// مجرى القراءة network-first: يبدأ من الخادم، وإن تعذّر عاد إلى آخر لقطة
/// محفوظة محلياً مع التصريح بذلك. قبل هذا كان أي خطأ في الشبكة يعيد الكاش
/// بلا تمييز، فكان رقم قديم (كـ 50 بدل 24) يظهر كأنه الأحدث ولا أحد يعرف
/// أنه قديم.
///
/// يُبطل يدوياً من `syncProvider` بعد كل مزامنة ناجحة، فيظهر أي تعديل جاء
/// من سطح المكتب.
///
/// يُعيد [FarmFetchResult] لا [FarmModel] مباشرةً، ليعرف الـ provider هل
/// القيمة حديثة من الخادم أم رجعنا للكاش بسبب انقطاع/رفض صلاحيات.
final farmSettingsProvider = FutureProvider.family<FarmFetchResult, String>((
  ref,
  farmId,
) async {
  return ref.read(farmRepositoryProvider).getFarmWithSource(farmId);
});

/// جلب كتالوج الأدوية
final medicinesCatalogProvider = FutureProvider<List<MedicineModel>>((
  ref,
) async {
  return ref.read(medicationRepositoryProvider).getMedicinesCatalog();
});

/// حالة تحميل البيانات المرجعية
final referenceDataReadyProvider = FutureProvider.autoDispose<void>((
  ref,
) async {
  return;
});
