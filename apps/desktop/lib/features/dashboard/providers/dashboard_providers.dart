import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'package:data/data.dart';

/// Provider لجلب إحصائيات لوحة القيادة للمدير
/// يجلب إجمالي الإنتاج، النفوق، المخزون، وحالة المزارع
final dashboardStatsProvider = FutureProvider.autoDispose.family<DashboardStats, String>((ref, farmId) async {
  final eggRepo = ref.read(eggProductionRepositoryProvider);
  final mortalityRepo = ref.read(mortalityRepositoryProvider);
  final feedRepo = ref.read(feedConsumptionRepositoryProvider);
  final flockRepo = ref.read(flockRepositoryProvider);

  // جلب بيانات آخر 7 أيام
  final now = DateTime.now();
  final weekAgo = now.subtract(const Duration(days: 7));

  // 1. إجمالي إنتاج البيض (آخر أسبوع)
  final eggRecords = await eggRepo.getAllRecords(
    farmId: farmId,
    fromDate: weekAgo,
    toDate: now,
  );
  final totalEggs = eggRecords.fold<int>(0, (sum, item) => sum + item.totalEggs);
  final totalBroken = eggRecords.fold<int>(0, (sum, item) => sum + item.brokenEggs);

  // 2. إجمالي النفوق (آخر أسبوع)
  final mortalityRecords = await mortalityRepo.getAllRecords(
    farmId: farmId,
    fromDate: weekAgo,
    toDate: now,
  );
  final totalDeaths = mortalityRecords.fold<int>(0, (sum, item) => sum + item.count);

  // 3. استهلاك العلف (آخر أسبوع)
  final feedRecords = await feedRepo.getAllRecords(
    farmId: farmId,
    fromDate: weekAgo,
    toDate: now,
  );
  final totalFeedKg = feedRecords.fold<double>(0, (sum, item) => sum + item.quantityKg);

  // 4. عدد القطعان النشطة
  final flocks = await flockRepo.getAllFlocks(farmId: farmId);
  final activeFlocks = flocks.where((f) => f.status == FlockStatus.active).length;

  return DashboardStats(
    totalEggs: totalEggs,
    brokenEggs: totalBroken,
    totalDeaths: totalDeaths,
    totalFeedKg: totalFeedKg,
    activeFlocksCount: activeFlocks,
    periodDays: 7,
  );
});

/// Provider لجلب قائمة المزارع للمدير
final allFarmsProvider = FutureProvider<List<FarmModel>>((ref) async {
  // ملاحظة: يتطلب FarmRepository، سنستخدم قائمة فارغة مؤقتاً إذا لم يكن موجوداً
  // في التطبيق الحقيقي، يجب تنفيذ FarmRepository
  try {
    // final farmRepo = ref.read(farmRepositoryProvider);
    // return await farmRepo.getAllFarms();
    return []; 
  } catch (e) {
    return [];
  }
});

/// نموذج بيانات للإحصائيات
class DashboardStats {
  final int totalEggs;
  final int brokenEggs;
  final int totalDeaths;
  final double totalFeedKg;
  final int activeFlocksCount;
  final int periodDays;

  DashboardStats({
    required this.totalEggs,
    required this.brokenEggs,
    required this.totalDeaths,
    required this.totalFeedKg,
    required this.activeFlocksCount,
    required this.periodDays,
  });

  double get avgDailyEggs => periodDays > 0 ? totalEggs / periodDays : 0;
  double get mortalityRate => activeFlocksCount > 0 ? (totalDeaths / (activeFlocksCount * 100)) * 100 : 0.0; // تقريبية
}
