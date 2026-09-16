import '../models/egg_production_model.dart';
import '../models/mortality_model.dart';
import '../models/feed_consumption_model.dart';
import '../models/feed_received_model.dart';
import '../models/dispatch_model.dart';
import '../models/payment_model.dart';
import '../models/expense_model.dart';
import '../models/flock_model.dart';
import '../models/customer_model.dart';
import '../models/inventory_model.dart';
import '../models/opening_balance_model.dart';
import '../utils/farm_analytics.dart';


/// ═══════════════════════════════════════════════════════════════
/// Phase 1 — Operational Intelligence Analytics Service
///
/// طبقة الحسابات التحليلية为核心的 for all Phase 1 features.
/// All functions are pure: input data → output metrics.
/// No database access, no network, no side effects.
///
/// All metrics are documented in docs/production/PHASE_1_METRICS.md
/// ═══════════════════════════════════════════════════════════════

// ─── Date Range Utilities ───

/// Represents a date range with a label
class DateRange {
  final DateTime from;
  final DateTime to;
  final String label;

  const DateRange({
    required this.from,
    required this.to,
    required this.label,
  });

  int get days => to.difference(from).inDays + 1;

  bool contains(DateTime date) =>
      !date.isBefore(from) && !date.isAfter(to);

  /// Standard filter presets
  static DateRange today() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    return DateRange(from: start, to: now, label: 'اليوم');
  }

  static DateRange yesterday() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day - 1);
    final end = DateTime(now.year, now.month, now.day - 1, 23, 59, 59);
    return DateRange(from: start, to: end, label: 'الأمس');
  }

  static DateRange last7Days() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 6));
    return DateRange(from: start, to: now, label: 'آخر 7 أيام');
  }

  static DateRange last30Days() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 29));
    return DateRange(from: start, to: now, label: 'آخر 30 يوم');
  }

  static DateRange thisMonth() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    return DateRange(from: start, to: now, label: 'هذا الشهر');
  }

  static DateRange previousMonth() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month - 1, 1);
    final end = DateTime(now.year, now.month, 0);
    return DateRange(from: start, to: end, label: 'الشهر السابق');
  }
}

// ─── Comparison Result ───

/// Result of comparing current vs previous period
class ComparisonResult<T> {
  final T current;
  final T previous;
  final double percentChange;
  final String trend; // 'up', 'down', 'stable'

  const ComparisonResult({
    required this.current,
    required this.previous,
    required this.percentChange,
    required this.trend,
  });

  factory ComparisonResult.fromValues({
    required T current,
    required T previous,
    required double Function(T a, T b) diff,
  }) {
    final d = diff(current, previous);
    return ComparisonResult(
      current: current,
      previous: previous,
      percentChange: d,
      trend: d > 0.5 ? 'up' : (d < -0.5 ? 'down' : 'stable'),
    );
  }

  bool get isUp => trend == 'up';
  bool get isDown => trend == 'down';
  bool get isStable => trend == 'stable';
}

// ═══════════════════════════════════════════════════════════════
// 1. PRODUCTION KPIs
// ═══════════════════════════════════════════════════════════════

class ProductionKpi {
  final int totalEggs;
  final int brokenEggs;
  final int dirtyEggs;
  final int sellableEggs;
  final double productionRate;
  final int daysWithData;

  const ProductionKpi({
    required this.totalEggs,
    required this.brokenEggs,
    required this.dirtyEggs,
    required this.sellableEggs,
    required this.productionRate,
    required this.daysWithData,
  });

  factory ProductionKpi.empty() => const ProductionKpi(
        totalEggs: 0,
        brokenEggs: 0,
        dirtyEggs: 0,
        sellableEggs: 0,
        productionRate: 0,
        daysWithData: 0,
      );

  double get wasteRate =>
      totalEggs > 0 ? (brokenEggs + dirtyEggs) / totalEggs * 100 : 0;

  double get avgDailyEggs =>
      daysWithData > 0 ? totalEggs / daysWithData : 0;

  /// Calculate production KPIs for a given set of records
  static ProductionKpi calculate({
    required List<EggProductionModel> records,
    required DateRange range,
    required int totalBirds,
  }) {
    final inRange = records.where((r) => range.contains(r.date)).toList();
    if (inRange.isEmpty || totalBirds <= 0) return ProductionKpi.empty();

    final total = inRange.fold<int>(0, (s, r) => s + r.totalEggs);
    final broken = inRange.fold<int>(0, (s, r) => s + r.brokenEggs);
    final dirty = inRange.fold<int>(0, (s, r) => s + r.dirtyEggs);

    return ProductionKpi(
      totalEggs: total,
      brokenEggs: broken,
      dirtyEggs: dirty,
      sellableEggs: total - broken - dirty,
      productionRate: FarmAnalytics.avgProductionRate(
        totalEggs: total,
        birdCount: totalBirds,
        days: range.days,
      ),
      daysWithData: inRange.length,
    );
  }

  /// Compare two production KPIs
  static ComparisonResult<ProductionKpi> compare({
    required ProductionKpi current,
    required ProductionKpi previous,
  }) {
    return ComparisonResult.fromValues(
      current: current,
      previous: previous,
      diff: (a, b) {
        if (b.totalEggs == 0) return a.totalEggs > 0 ? 100 : 0;
        return (a.totalEggs - b.totalEggs) / b.totalEggs * 100;
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 2. MORTALITY KPIs
// ═══════════════════════════════════════════════════════════════

class MortalityKpi {
  final int totalDeaths;
  final double dailyRate;
  final String level; // 'ok', 'warning', 'danger'
  final int daysWithData;
  final Map<String, int> deathsByReason;

  const MortalityKpi({
    required this.totalDeaths,
    required this.dailyRate,
    required this.level,
    required this.daysWithData,
    required this.deathsByReason,
  });

  factory MortalityKpi.empty() => const MortalityKpi(
        totalDeaths: 0,
        dailyRate: 0,
        level: 'ok',
        daysWithData: 0,
        deathsByReason: {},
      );

  /// Calculate mortality KPIs
  static MortalityKpi calculate({
    required List<MortalityModel> records,
    required DateRange range,
    required int totalBirds,
    int openingBalanceMortality = 0,
  }) {
    final inRange = records.where((r) => range.contains(r.date)).toList();

    // Include opening balance mortality in total deaths
    final totalDeaths =
        inRange.fold<int>(0, (s, r) => s + r.count) + openingBalanceMortality;

    if (totalDeaths == 0) return MortalityKpi.empty();

    final rate = FarmAnalytics.dailyMortalityRate(
      totalDeaths: totalDeaths,
      birdCount: totalBirds,
      days: range.days,
    );

    // Group by reason
    final byReason = <String, int>{};
    for (final r in inRange) {
      final reason = r.reason.name;
      byReason[reason] = (byReason[reason] ?? 0) + r.count;
    }
    if (openingBalanceMortality > 0) {
      byReason['opening_balance'] =
          (byReason['opening_balance'] ?? 0) + openingBalanceMortality;
    }

    return MortalityKpi(
      totalDeaths: totalDeaths,
      dailyRate: rate,
      level: FarmAnalytics.mortalityLevel(rate),
      daysWithData: inRange.length,
      deathsByReason: byReason,
    );
  }

  static ComparisonResult<MortalityKpi> compare({
    required MortalityKpi current,
    required MortalityKpi previous,
  }) {
    return ComparisonResult.fromValues(
      current: current,
      previous: previous,
      diff: (a, b) {
        if (b.totalDeaths == 0) return a.totalDeaths > 0 ? 100 : 0;
        return (a.totalDeaths - b.totalDeaths) / b.totalDeaths * 100;
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 3. FEED KPIs
// ═══════════════════════════════════════════════════════════════

class FeedKpi {
  final double consumedKg;
  final double receivedKg;
  final double stockKg;
  final double avgDailyConsumptionKg;
  final double? daysRemaining;
  final String level; // 'ok', 'warning', 'danger', 'unknown'
  final double feedPerBird;

  const FeedKpi({
    required this.consumedKg,
    required this.receivedKg,
    required this.stockKg,
    required this.avgDailyConsumptionKg,
    required this.daysRemaining,
    required this.level,
    required this.feedPerBird,
  });

  factory FeedKpi.empty() => const FeedKpi(
        consumedKg: 0,
        receivedKg: 0,
        stockKg: 0,
        avgDailyConsumptionKg: 0,
        daysRemaining: null,
        level: 'unknown',
        feedPerBird: 0,
      );

  /// Calculate feed KPIs
  static FeedKpi calculate({
    required List<FeedConsumptionModel> consumption,
    required List<FeedReceivedModel> received,
    required DateRange range,
    required int totalBirds,
    required double currentStockKg,
  }) {
    final consumedInRange = consumption
        .where((r) => range.contains(r.date))
        .fold<double>(0, (s, r) => s + r.quantityKg);

    final receivedInRange = received
        .where((r) => range.contains(r.date))
        .fold<double>(0, (s, r) => s + r.quantityKg);

    final avgDaily = range.days > 0 ? consumedInRange / range.days : 0.0;
    final daysLeft = FarmAnalytics.feedDaysLeft(
      stockKg: currentStockKg,
      avgDailyConsumptionKg: avgDaily,
    );

    return FeedKpi(
      consumedKg: consumedInRange,
      receivedKg: receivedInRange,
      stockKg: currentStockKg,
      avgDailyConsumptionKg: avgDaily,
      daysRemaining: daysLeft,
      level: FarmAnalytics.feedLevel(daysLeft),
      feedPerBird: totalBirds > 0 ? consumedInRange / totalBirds : 0,
    );
  }

  static ComparisonResult<FeedKpi> compare({
    required FeedKpi current,
    required FeedKpi previous,
  }) {
    return ComparisonResult.fromValues(
      current: current,
      previous: previous,
      diff: (a, b) {
        if (b.consumedKg == 0) return a.consumedKg > 0 ? 100 : 0;
        return (a.consumedKg - b.consumedKg) / b.consumedKg * 100;
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 4. FINANCIAL KPIs
// ═══════════════════════════════════════════════════════════════

class FinancialKpi {
  final double totalSales; // totalDue from dispatches
  final double totalCollected; // amountPaid from payments
  final double totalExpenses;
  final double outstanding; // totalDue - totalPaid
  final double estimatedMargin; // collected - expenses (estimate)

  const FinancialKpi({
    required this.totalSales,
    required this.totalCollected,
    required this.totalExpenses,
    required this.outstanding,
    required this.estimatedMargin,
  });

  factory FinancialKpi.empty() => const FinancialKpi(
        totalSales: 0,
        totalCollected: 0,
        totalExpenses: 0,
        outstanding: 0,
        estimatedMargin: 0,
      );

  static FinancialKpi calculate({
    required List<DispatchModel> dispatches,
    required List<PaymentModel> payments,
    required List<ExpenseModel> expenses,
    required DateRange range,
  }) {
    final sales = payments
        .where((p) => range.contains(p.date))
        .fold<double>(0, (s, p) => s + p.totalDue);

    final collected = payments
        .where((p) => range.contains(p.date))
        .fold<double>(0, (s, p) => s + p.amountPaid);

    final exp = expenses
        .where((e) => range.contains(e.date))
        .fold<double>(0, (s, e) => s + e.amount);

    final outstanding = payments
        .where((p) => !p.isPaid)
        .fold<double>(0, (s, p) => s + (p.totalDue - p.amountPaid));

    return FinancialKpi(
      totalSales: sales,
      totalCollected: collected,
      totalExpenses: exp,
      outstanding: outstanding,
      estimatedMargin: collected - exp,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 5. FLOCK PERFORMANCE
// ═══════════════════════════════════════════════════════════════

class FlockPerformance {
  final String flockId;
  final String breed;
  final int initialCount;
  final int currentCount;
  final int ageDays;
  final String status;
  final ProductionKpi production;
  final MortalityKpi mortality;
  final FeedKpi feed;
  final double eggsPerBird;
  final double feedPerBird;
  final double estimatedRevenue;
  final double estimatedCost;
  final double estimatedMargin;
  final double costPerEgg;
  final double marginPerEgg;

  const FlockPerformance({
    required this.flockId,
    required this.breed,
    required this.initialCount,
    required this.currentCount,
    required this.ageDays,
    required this.status,
    required this.production,
    required this.mortality,
    required this.feed,
    required this.eggsPerBird,
    required this.feedPerBird,
    required this.estimatedRevenue,
    required this.estimatedCost,
    required this.estimatedMargin,
    required this.costPerEgg,
    required this.marginPerEgg,
  });

  /// Calculate full flock performance
  static FlockPerformance calculate({
    required FlockModel flock,
    required List<EggProductionModel> eggs,
    required List<MortalityModel> mortality,
    required List<FeedConsumptionModel> feedConsumption,
    required List<FeedReceivedModel> feedReceived,
    required List<DispatchModel> dispatches,
    required List<PaymentModel> payments,
    required List<ExpenseModel> expenses,
    required DateRange range,
    double pricePerEgg = 0,
    OpeningBalanceModel? openingBalance,
  }) {
    final flockEggs = eggs.where((e) => e.flockId == flock.id).toList();
    final flockMortality =
        mortality.where((m) => m.flockId == flock.id).toList();
    final flockFeed =
        feedConsumption.where((f) => f.flockId == flock.id).toList();
    final flockFeedReceived =
        feedReceived.where((f) => f.flockId == flock.id).toList();
    final flockDispatches =
        dispatches.where((d) => d.flockId == flock.id).toList();
    final flockPayments = payments.where((p) {
      return flockDispatches.any((d) => d.id == p.dispatchId);
    }).toList();

    final production = ProductionKpi.calculate(
      records: flockEggs,
      range: range,
      totalBirds: flock.currentCount,
    );

    final mortalityKpi = MortalityKpi.calculate(
      records: flockMortality,
      range: range,
      totalBirds: flock.currentCount,
      openingBalanceMortality: openingBalance?.mortalityCount ?? 0,
    );

    final feedKpi = FeedKpi.calculate(
      consumption: flockFeed,
      received: flockFeedReceived,
      range: range,
      totalBirds: flock.currentCount,
      currentStockKg: 0,
    );

    final revenue = flockPayments.fold<double>(0, (s, p) => s + p.totalDue);
    final cost = flockFeed.fold<double>(0, (s, f) => s + f.quantityKg) *
        (pricePerEgg > 0 ? pricePerEgg : 0);
    final totalEggs = production.totalEggs;

    return FlockPerformance(
      flockId: flock.id,
      breed: flock.breed,
      initialCount: flock.initialCount,
      currentCount: flock.currentCount,
      ageDays: DateTime.now().difference(flock.startDate).inDays,
      status: flock.status.name,
      production: production,
      mortality: mortalityKpi,
      feed: feedKpi,
      eggsPerBird: flock.currentCount > 0
          ? production.totalEggs / flock.currentCount
          : 0,
      feedPerBird: flock.currentCount > 0
          ? feedKpi.consumedKg / flock.currentCount
          : 0,
      estimatedRevenue: revenue,
      estimatedCost: cost,
      estimatedMargin: revenue - cost,
      costPerEgg: totalEggs > 0 ? cost / totalEggs : 0,
      marginPerEgg: totalEggs > 0 ? (revenue - cost) / totalEggs : 0,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 6. CUSTOMER 360
// ═══════════════════════════════════════════════════════════════

class CustomerAnalytics {
  final String customerId;
  final String name;
  final String phone;
  final int totalDispatches;
  final int totalEggs;
  final double totalSales;
  final double totalPaid;
  final double outstanding;
  final DateTime? lastTransaction;
  final double avgTransaction;
  final String classification; // 'good', 'normal', 'attention'

  const CustomerAnalytics({
    required this.customerId,
    required this.name,
    required this.phone,
    required this.totalDispatches,
    required this.totalEggs,
    required this.totalSales,
    required this.totalPaid,
    required this.outstanding,
    required this.lastTransaction,
    required this.avgTransaction,
    required this.classification,
  });

  static CustomerAnalytics calculate({
    required CustomerModel customer,
    required List<DispatchModel> dispatches,
    required List<PaymentModel> payments,
  }) {
    final custDispatches = dispatches
        .where((d) => d.customerId == customer.id)
        .toList();
    final custPayments = payments
        .where((p) => p.customerId == customer.id)
        .toList();

    final totalSales =
        custPayments.fold<double>(0, (s, p) => s + p.totalDue);
    final totalPaid =
        custPayments.fold<double>(0, (s, p) => s + p.amountPaid);
    final totalEggs =
        custDispatches.fold<int>(0, (s, d) => s + d.totalEggs);

    DateTime? lastTx;
    for (final d in custDispatches) {
      if (lastTx == null || d.date.isAfter(lastTx)) lastTx = d.date;
    }
    for (final p in custPayments) {
      if (lastTx == null || p.date.isAfter(lastTx)) lastTx = p.date;
    }

    final avgTx =
        custDispatches.isNotEmpty ? totalSales / custDispatches.length : 0.0;

    final outstanding = customer.totalDebt;
    final classification = outstanding > 1000
        ? 'attention'
        : (totalPaid > 0 ? 'good' : 'normal');

    return CustomerAnalytics(
      customerId: customer.id ?? '',
      name: customer.name ?? '',
      phone: customer.phone ?? '',
      totalDispatches: custDispatches.length,
      totalEggs: totalEggs,
      totalSales: totalSales,
      totalPaid: totalPaid,
      outstanding: outstanding,
      lastTransaction: lastTx,
      avgTransaction: avgTx,
      classification: classification,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 7. SUPPLIER INTELLIGENCE
// ═══════════════════════════════════════════════════════════════

class SupplierAnalytics {
  final String supplierName;
  final int totalShipments;
  final double totalKg;
  final double totalCost;
  final double avgPricePerKg;
  final DateTime? lastShipment;
  final String feedType;

  const SupplierAnalytics({
    required this.supplierName,
    required this.totalShipments,
    required this.totalKg,
    required this.totalCost,
    required this.avgPricePerKg,
    required this.lastShipment,
    required this.feedType,
  });

  /// Aggregate feed_received by supplier
  static List<SupplierAnalytics> calculateFromFeed({
    required List<FeedReceivedModel> received,
    required DateRange range,
  }) {
    final inRange = received.where((r) => range.contains(r.date)).toList();

    // Group by supplier
    final grouped = <String, List<FeedReceivedModel>>{};
    for (final r in inRange) {
      final supplier = r.supplier ?? 'غير محدد';
      grouped.putIfAbsent(supplier, () => []).add(r);
    }

    return grouped.entries.map((entry) {
      final shipments = entry.value;
      final totalKg =
          shipments.fold<double>(0, (s, r) => s + r.quantityKg);
      final totalCost = shipments.fold<double>(
          0, (s, r) => s + (r.pricePerKg ?? 0) * r.quantityKg);
      final pricesWithValues =
          shipments.where((r) => r.pricePerKg != null).toList();
      final avgPrice = pricesWithValues.isNotEmpty
          ? pricesWithValues.fold<double>(
                  0, (s, r) => s + r.pricePerKg!) /
              pricesWithValues.length
          : 0.0;

      DateTime? last;
      for (final s in shipments) {
        if (last == null || s.date.isAfter(last)) last = s.date;
      }

      return SupplierAnalytics(
        supplierName: entry.key,
        totalShipments: shipments.length,
        totalKg: totalKg,
        totalCost: totalCost,
        avgPricePerKg: avgPrice,
        lastShipment: last,
        feedType: shipments.first.feedType.name,
      );
    }).toList()
      ..sort((a, b) => b.totalCost.compareTo(a.totalCost));
  }
}

// ═══════════════════════════════════════════════════════════════
// 8. COST PER EGG
// ═══════════════════════════════════════════════════════════════

class CostPerEgg {
  final double feedCost;
  final double medicationCost;
  final double expensesCost;
  final double totalCost;
  final int totalEggs;
  final double costPerEgg;

  const CostPerEgg({
    required this.feedCost,
    required this.medicationCost,
    required this.expensesCost,
    required this.totalCost,
    required this.totalEggs,
    required this.costPerEgg,
  });

  factory CostPerEgg.empty() => const CostPerEgg(
        feedCost: 0,
        medicationCost: 0,
        expensesCost: 0,
        totalCost: 0,
        totalEggs: 0,
        costPerEgg: 0,
      );

  /// Calculate cost per egg for a farm
  ///
  /// Only includes costs that can be attributed to the farm:
  /// - Feed received (price * quantity)
  /// - Medications (count-based, no price in schema → estimated)
  /// - Expenses (all categories)
  ///
  /// If totalEggs is 0, costPerEgg is 0 (no division by zero).
  static CostPerEgg calculate({
    required List<FeedReceivedModel> feedReceived,
    required List<ExpenseModel> expenses,
    required List<EggProductionModel> eggs,
    required DateRange range,
  }) {
    final feedCost = feedReceived
        .where((r) => range.contains(r.date))
        .fold<double>(0, (s, r) => s + (r.pricePerKg ?? 0) * r.quantityKg);

    final expensesCost = expenses
        .where((e) => range.contains(e.date))
        .fold<double>(0, (s, e) => s + e.amount);

    final totalEggs = eggs
        .where((e) => range.contains(e.date))
        .fold<int>(0, (s, e) => s + e.totalEggs);

    final totalCost = feedCost + expensesCost;

    return CostPerEgg(
      feedCost: feedCost,
      medicationCost: 0, // No price field in medications table
      expensesCost: expensesCost,
      totalCost: totalCost,
      totalEggs: totalEggs,
      costPerEgg: totalEggs > 0 ? totalCost / totalEggs : 0,
    );
  }

  /// Calculate cost per egg for a specific flock
  static CostPerEgg calculateForFlock({
    required List<FeedReceivedModel> feedReceived,
    required List<ExpenseModel> expenses,
    required List<EggProductionModel> eggs,
    required DateRange range,
    required String flockId,
    required double flockShareRatio,
  }) {
    final flockFeedCost = feedReceived
        .where((r) => range.contains(r.date) && r.flockId == flockId)
        .fold<double>(0, (s, r) => s + (r.pricePerKg ?? 0) * r.quantityKg);

    // Shared expenses proportional to flock's egg production
    final totalFarmEggs = eggs
        .where((e) => range.contains(e.date))
        .fold<int>(0, (s, e) => s + e.totalEggs);
    final sharedExpenses = expenses
        .where((e) => range.contains(e.date))
        .fold<double>(0, (s, e) => s + e.amount);
    final flockExpenses = totalFarmEggs > 0
        ? sharedExpenses * flockShareRatio
        : 0.0;

    final flockEggs = eggs
        .where((e) => range.contains(e.date) && e.flockId == flockId)
        .fold<int>(0, (s, e) => s + e.totalEggs);

    final totalCost = flockFeedCost + flockExpenses;

    return CostPerEgg(
      feedCost: flockFeedCost,
      medicationCost: 0,
      expensesCost: flockExpenses,
      totalCost: totalCost,
      totalEggs: flockEggs,
      costPerEgg: flockEggs > 0 ? totalCost / flockEggs : 0,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 9. PROFITABILITY PER FLOCK
// ═══════════════════════════════════════════════════════════════

class FlockProfitability {
  final String flockId;
  final String breed;
  final double revenue;
  final double feedCost;
  final double expensesCost;
  final double totalCost;
  final double estimatedMargin;
  final double marginPerEgg;
  final double marginPercent;
  final int totalEggs;
  final String classification; // 'profitable', 'breakeven', 'loss'

  const FlockProfitability({
    required this.flockId,
    required this.breed,
    required this.revenue,
    required this.feedCost,
    required this.expensesCost,
    required this.totalCost,
    required this.estimatedMargin,
    required this.marginPerEgg,
    required this.marginPercent,
    required this.totalEggs,
    required this.classification,
  });

  factory FlockProfitability.empty() => const FlockProfitability(
        flockId: '',
        breed: '',
        revenue: 0,
        feedCost: 0,
        expensesCost: 0,
        totalCost: 0,
        estimatedMargin: 0,
        marginPerEgg: 0,
        marginPercent: 0,
        totalEggs: 0,
        classification: 'breakeven',
      );

  /// Calculate profitability for a single flock
  static FlockProfitability calculate({
    required FlockModel flock,
    required List<EggProductionModel> eggs,
    required List<DispatchModel> dispatches,
    required List<PaymentModel> payments,
    required List<FeedReceivedModel> feedReceived,
    required List<ExpenseModel> expenses,
    required DateRange range,
    required double pricePerEgg,
    required int totalFarmEggs,
  }) {
    // Revenue: sum of payments for this flock's dispatches
    final flockDispatches =
        dispatches.where((d) => d.flockId == flock.id).toList();
    final dispatchIds =
        flockDispatches.map((d) => d.id).whereType<String>().toSet();
    final flockPayments = payments
        .where((p) => p.dispatchId != null && dispatchIds.contains(p.dispatchId))
        .toList();
    final revenue =
        flockPayments.fold<double>(0, (s, p) => s + p.amountPaid);

    // Feed cost: direct + shared
    final directFeedCost = feedReceived
        .where((r) => range.contains(r.date) && r.flockId == flock.id)
        .fold<double>(0, (s, r) => s + (r.pricePerKg ?? 0) * r.quantityKg);

    // Shared expenses proportional to egg production
    final flockEggs = eggs
        .where((e) => range.contains(e.date) && e.flockId == flock.id)
        .fold<int>(0, (s, e) => s + e.totalEggs);
    final farmTotalEggs = eggs
        .where((e) => range.contains(e.date))
        .fold<int>(0, (s, e) => s + e.totalEggs);
    final farmExpenses = expenses
        .where((e) => range.contains(e.date))
        .fold<double>(0, (s, e) => s + e.amount);
    final sharedExpenses =
        farmTotalEggs > 0 ? farmExpenses * (flockEggs / farmTotalEggs) : 0.0;

    final totalCost = directFeedCost + sharedExpenses;
    final margin = revenue - totalCost;
    final marginPercent = revenue > 0 ? (margin / revenue * 100).toDouble() : 0.0;

    String classification;
    if (margin > 0) {
      classification = 'profitable';
    } else if (margin.abs() < revenue * 0.05) {
      classification = 'breakeven';
    } else {
      classification = 'loss';
    }

    return FlockProfitability(
      flockId: flock.id,
      breed: flock.breed,
      revenue: revenue,
      feedCost: directFeedCost,
      expensesCost: sharedExpenses,
      totalCost: totalCost,
      estimatedMargin: margin,
      marginPerEgg: flockEggs > 0 ? margin / flockEggs : 0,
      marginPercent: marginPercent,
      totalEggs: flockEggs,
      classification: classification,
    );
  }

  /// Rank all flocks by profitability
  static List<FlockProfitability> rankAll({
    required List<FlockModel> flocks,
    required List<EggProductionModel> eggs,
    required List<DispatchModel> dispatches,
    required List<PaymentModel> payments,
    required List<FeedReceivedModel> feedReceived,
    required List<ExpenseModel> expenses,
    required DateRange range,
    required double pricePerEgg,
  }) {
    final totalFarmEggs = eggs
        .where((e) => range.contains(e.date))
        .fold<int>(0, (s, e) => s + e.totalEggs);

    return flocks.map((flock) {
      return calculate(
        flock: flock,
        eggs: eggs,
        dispatches: dispatches,
        payments: payments,
        feedReceived: feedReceived,
        expenses: expenses,
        range: range,
        pricePerEgg: pricePerEgg,
        totalFarmEggs: totalFarmEggs,
      );
    }).toList()
      ..sort((a, b) => b.estimatedMargin.compareTo(a.estimatedMargin));
  }
}

// ═══════════════════════════════════════════════════════════════
// 10. LOW STOCK ALERTS
// ═══════════════════════════════════════════════════════════════

class StockAlert {
  final String itemId;
  final String itemName;
  final double currentQuantity;
  final double threshold;
  final String unit;
  final String status; // 'normal', 'low', 'critical'
  final double? avgDailyUsage;
  final double? daysRemaining;

  const StockAlert({
    required this.itemId,
    required this.itemName,
    required this.currentQuantity,
    required this.threshold,
    required this.unit,
    required this.status,
    this.avgDailyUsage,
    this.daysRemaining,
  });

  static String classify(double quantity, double threshold) {
    if (quantity <= 0) return 'critical';
    if (quantity <= threshold * 0.5) return 'critical';
    if (quantity <= threshold) return 'low';
    return 'normal';
  }

  static List<StockAlert> calculate({
    required List<InventoryItemModel> items,
    List<InventoryTransactionModel>? transactions,
  }) {
    return items.map((item) {
      final qty = item.quantity ?? 0;
      final threshold = item.lowStockThreshold ?? 0;
      final status = classify(qty, threshold);

      return StockAlert(
        itemId: item.id ?? '',
        itemName: item.name ?? '',
        currentQuantity: qty,
        threshold: threshold,
        unit: item.unit?.name ?? '',
        status: status,
      );
    }).toList()
      ..sort((a, b) {
        const order = {'critical': 0, 'low': 1, 'normal': 2};
        return (order[a.status] ?? 2).compareTo(order[b.status] ?? 2);
      });
  }
}

// ═══════════════════════════════════════════════════════════════
// 11. DAILY TREND DATA (for charts)
// ═══════════════════════════════════════════════════════════════

class DailyTrend {
  final DateTime date;
  final int eggs;
  final int mortality;
  final double feedKg;

  const DailyTrend({
    required this.date,
    required this.eggs,
    required this.mortality,
    required this.feedKg,
  });
}

/// Build daily trend from raw records
List<DailyTrend> buildDailyTrend({
  required List<EggProductionModel> eggs,
  required List<MortalityModel> mortality,
  required List<FeedConsumptionModel> feed,
  required DateRange range,
}) {
  final trends = <String, DailyTrend>{};

  for (final e in eggs.where((r) => range.contains(r.date))) {
    final key = '${e.date.year}-${e.date.month}-${e.date.day}';
    final existing = trends[key];
    trends[key] = DailyTrend(
      date: DateTime(e.date.year, e.date.month, e.date.day),
      eggs: (existing?.eggs ?? 0) + e.totalEggs,
      mortality: existing?.mortality ?? 0,
      feedKg: existing?.feedKg ?? 0,
    );
  }

  for (final m in mortality.where((r) => range.contains(r.date))) {
    final key = '${m.date.year}-${m.date.month}-${m.date.day}';
    final existing = trends[key];
    trends[key] = DailyTrend(
      date: DateTime(m.date.year, m.date.month, m.date.day),
      eggs: existing?.eggs ?? 0,
      mortality: (existing?.mortality ?? 0) + m.count,
      feedKg: existing?.feedKg ?? 0,
    );
  }

  for (final f in feed.where((r) => range.contains(r.date))) {
    final key = '${f.date.year}-${f.date.month}-${f.date.day}';
    final existing = trends[key];
    trends[key] = DailyTrend(
      date: DateTime(f.date.year, f.date.month, f.date.day),
      eggs: existing?.eggs ?? 0,
      mortality: existing?.mortality ?? 0,
      feedKg: (existing?.feedKg ?? 0) + f.quantityKg,
    );
  }

  final sorted = trends.values.toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  return sorted;
}

// ═══════════════════════════════════════════════════════════════
// 12. ANOMALY DETECTION
// ═══════════════════════════════════════════════════════════════

class ProductionAnomaly {
  final DateTime date;
  final int actualEggs;
  final double averageEggs;
  final double dropPercent;
  final String severity; // 'warning', 'critical'

  const ProductionAnomaly({
    required this.date,
    required this.actualEggs,
    required this.averageEggs,
    required this.dropPercent,
    required this.severity,
  });
}

/// Detect production anomalies using 7-day moving average
List<ProductionAnomaly> detectProductionAnomalies({
  required List<EggProductionModel> eggs,
  required int birdCount,
  double warningThreshold = 15,
  double criticalThreshold = 25,
}) {
  if (eggs.length < 7) return [];

  final sorted = List<EggProductionModel>.from(eggs)
    ..sort((a, b) => a.date.compareTo(b.date));

  final anomalies = <ProductionAnomaly>[];

  for (int i = 7; i < sorted.length; i++) {
    // 7-day average before this day
    final window = sorted.sublist(i - 7, i);
    final avg7Day =
        window.fold<int>(0, (s, e) => s + e.totalEggs) / 7;
    final today = sorted[i];

    if (avg7Day <= 0 || birdCount <= 0) continue;

    final avgRate = avg7Day / birdCount * 100;
    final todayRate = today.totalEggs / birdCount * 100;
    final drop = avgRate - todayRate;

    if (drop >= criticalThreshold) {
      anomalies.add(ProductionAnomaly(
        date: today.date,
        actualEggs: today.totalEggs,
        averageEggs: avg7Day,
        dropPercent: drop,
        severity: 'critical',
      ));
    } else if (drop >= warningThreshold) {
      anomalies.add(ProductionAnomaly(
        date: today.date,
        actualEggs: today.totalEggs,
        averageEggs: avg7Day,
        dropPercent: drop,
        severity: 'warning',
      ));
    }
  }

  return anomalies;
}
