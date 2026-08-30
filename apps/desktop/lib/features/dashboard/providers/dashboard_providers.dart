import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'package:data/data.dart';

/// Provider لجلب إحصائيات لوحة القيادة للمدير (لكل المزارع)
final dailyStatsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final eggRepo = ref.read(eggProductionRepositoryProvider);
  final mortalityRepo = ref.read(mortalityRepositoryProvider);
  final feedRepo = ref.read(feedConsumptionRepositoryProvider);
  final farmsRepo = ref.read(farmRepositoryProvider);
  
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  
  try {
    // جلب كل المزارع
    final farms = await farmsRepo.getAllFarms();
    
    int totalEggs = 0;
    int totalMortality = 0;
    double totalFeed = 0.0;
    double netProfit = 0.0;
    
    for (var farm in farms) {
      // إنتاج اليوم
      final eggsToday = await eggRepo.getTodayRecords(farm.id);
      totalEggs += eggsToday.fold<int>(0, (sum, item) => sum + item.totalEggs);
      
      // نفوق اليوم
      final mortalityToday = await mortalityRepo.getTodayRecords(farm.id);
      totalMortality += mortalityToday.fold<int>(0, (sum, item) => sum + item.count);
      
      // علف اليوم
      final feedToday = await feedRepo.getTodayRecords(farm.id);
      totalFeed += feedToday.fold<double>(0, (sum, item) => sum + item.quantityKg);
    }
    
    // حساب الربح التقريبي (سعر الكرتون × عدد الكراتين - تكلفة العلف)
    final avgPricePerCarton = 15.0; // متوسط سعر الكرتون (افتراضي)
    final cartonsProduced = totalEggs ~/ 360; // تقسيم على 360 بيضة في الكرتون
    final revenue = cartonsProduced * avgPricePerCarton;
    final feedCost = totalFeed * 1.2; // تكلفة كيلو العلف تقريباً
    netProfit = revenue - feedCost;
    
    return {
      'total_eggs': totalEggs,
      'total_mortality': totalMortality,
      'mortality_rate': farms.isNotEmpty ? (totalMortality / (farms.length * 1000)) * 100 : 0.0,
      'total_feed': totalFeed.toStringAsFixed(1),
      'net_profit': netProfit.toStringAsFixed(2),
    };
  } catch (e) {
    return {
      'total_eggs': 0,
      'total_mortality': 0,
      'mortality_rate': 0.0,
      'total_feed': '0.0',
      'net_profit': '0.00',
      'error': e.toString(),
    };
  }
});

/// Provider لجلب قائمة المزارع مع حالتها
final farmsProvider = FutureProvider<List<dynamic>>((ref) async {
  try {
    final farmsRepo = ref.read(farmRepositoryProvider);
    final farms = await farmsRepo.getAllFarms();
    
    // إضافة معلومات إضافية لكل مزرعة
    return farms.map((farm) => {
      'id': farm.id,
      'name': farm.name,
      'ownerName': farm.ownerName,
      'activeFlocks': 0, // يمكن حسابها لاحقاً
      'mortality_rate': 0.0, // يمكن حسابها من البيانات
    }).toList();
  } catch (e) {
    return [];
  }
});

/// Provider لاتجاه الإنتاج (آخر 7 أيام)
final productionTrendProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  try {
    final eggRepo = ref.read(eggProductionRepositoryProvider);
    final now = DateTime.now();
    final trendData = <Map<String, dynamic>>[];
    
    for (int i = 6; i >= 0; i--) {
      final date = now.subtract(Duration(days: i));
      final startOfDay = DateTime(date.year, date.month, date.day);
      final endOfDay = startOfDay.add(const Duration(days: 1));
      
      final records = await eggRepo.getAllRecords(
        fromDate: startOfDay,
        toDate: endOfDay,
      );
      
      final totalEggs = records.fold<int>(0, (sum, item) => sum + item.totalEggs);
      trendData.add({'date': startOfDay, 'eggs': totalEggs});
    }
    
    return trendData;
  } catch (e) {
    return [];
  }
});

/// Provider لجلب تنبيهات هامة
final alertsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  // TODO: تنفيذ منطق جلب التنبيهات من قاعدة البيانات
  return [
    {'title': 'نقص في مخزون العلف', 'subtitle': 'يتبقى 2 طن فقط', 'type': 'warning'},
    {'title': 'ارتفاع معدل النفوق', 'subtitle': 'في مزرعة 1', 'type': 'critical'},
  ];
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
  double get mortalityRate => activeFlocksCount > 0 ? (totalDeaths / (activeFlocksCount * 100)) * 100 : 0.0;
}
