import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'providers.dart';

/// ═══════════════════════════════════════════════════════════════
/// Phase 1 Analytics Providers — Desktop
/// ═══════════════════════════════════════════════════════════════

final productionKpiProvider = FutureProvider.autoDispose
    .family<ProductionKpi, ({String farmId, DateRange range})>(
        (ref, params) async {
  final eggs = await ref.read(eggProductionRepositoryProvider).getAllRecords(
    farmId: params.farmId,
    fromDate: params.range.from,
    toDate: params.range.to,
  );
  final flocks =
      await ref.read(flockRepositoryProvider).getFlocks(params.farmId);
  final totalBirds = flocks
      .where((f) => f.status == FlockStatus.active)
      .fold<int>(0, (s, f) => s + f.currentCount);

  // الأرصدة الافتتاحية (قطيعة قديمة قبل النظام) — بيض مُنتَج في الماضي
  final openingBalances =
      await ref.read(openingBalanceRepositoryProvider).getForFarm(params.farmId);
  final openingEggsTotal =
      openingBalances.fold<int>(0, (s, b) => s + b.eggsProduced);

  return ProductionKpi.calculate(
    records: eggs,
    range: params.range,
    totalBirds: totalBirds,
    openingBalanceEggs: openingEggsTotal,
  );
});

final mortalityKpiProvider = FutureProvider.autoDispose
    .family<MortalityKpi, ({String farmId, DateRange range})>(
        (ref, params) async {
  final mortality = await ref
      .read(mortalityRepositoryProvider)
      .getAllRecords(
        farmId: params.farmId,
        fromDate: params.range.from,
        toDate: params.range.to,
      );
  final flocks =
      await ref.read(flockRepositoryProvider).getFlocks(params.farmId);
  final totalBirds = flocks
      .where((f) => f.status == FlockStatus.active)
      .fold<int>(0, (s, f) => s + f.currentCount);

  // P0: Include opening balance mortality
  final openingBalances =
      await ref.read(openingBalanceRepositoryProvider).getForFarm(params.farmId);
  final openingMortalityTotal =
      openingBalances.fold<int>(0, (s, b) => s + b.mortalityCount);

  return MortalityKpi.calculate(
    records: mortality,
    range: params.range,
    totalBirds: totalBirds,
    openingBalanceMortality: openingMortalityTotal,
  );
});

final feedKpiProvider = FutureProvider.autoDispose
    .family<FeedKpi, ({String farmId, DateRange range, double stockKg})>(
        (ref, params) async {
  final consumption = await ref
      .read(feedRepositoryProvider)
      .getAllConsumption(
        farmId: params.farmId,
        fromDate: params.range.from,
        toDate: params.range.to,
      );
  final received = await ref
      .read(feedRepositoryProvider)
      .getAllReceived(
        farmId: params.farmId,
        fromDate: params.range.from,
        toDate: params.range.to,
      );
  final flocks =
      await ref.read(flockRepositoryProvider).getFlocks(params.farmId);
  final totalBirds = flocks
      .where((f) => f.status == FlockStatus.active)
      .fold<int>(0, (s, f) => s + f.currentCount);

  return FeedKpi.calculate(
    consumption: consumption,
    received: received,
    range: params.range,
    totalBirds: totalBirds,
    currentStockKg: params.stockKg,
  );
});

final financialKpiProvider = FutureProvider.autoDispose
    .family<FinancialKpi, ({String farmId, DateRange range})>(
        (ref, params) async {
  final dispatches = await ref.read(dispatchRepositoryProvider).getAll(
    farmId: params.farmId,
    fromDate: params.range.from,
    toDate: params.range.to,
  );
  final payments = await ref.read(paymentRepositoryProvider).getAll(
    farmId: params.farmId,
    fromDate: params.range.from,
    toDate: params.range.to,
  );
  final expenses = await ref.read(expenseRepositoryProvider).getExpenses(
    farmId: params.farmId,
    fromDate: params.range.from,
    toDate: params.range.to,
  );

  return FinancialKpi.calculate(
    dispatches: dispatches,
    payments: payments,
    expenses: expenses,
    range: params.range,
  );
});

final stockAlertsProvider = FutureProvider.autoDispose
    .family<List<StockAlert>, String>((ref, farmId) async {
  final items = await ref.read(inventoryRepositoryProvider).getItems(farmId);
  return StockAlert.calculate(items: items);
});

final customerAnalyticsProvider = FutureProvider.autoDispose
    .family<List<CustomerAnalytics>, String>((ref, farmId) async {
  final customers =
      await ref.read(dispatchRepositoryProvider).getCustomers(farmId);
  final dispatches =
      await ref.read(dispatchRepositoryProvider).getAll(farmId: farmId);
  final payments =
      await ref.read(paymentRepositoryProvider).getAll(farmId: farmId);

  return customers.map((customer) {
    return CustomerAnalytics.calculate(
      customer: customer,
      dispatches: dispatches,
      payments: payments,
    );
  }).toList()
    ..sort((a, b) => b.totalSales.compareTo(a.totalSales));
});

final supplierAnalyticsProvider = FutureProvider.autoDispose
    .family<List<SupplierAnalytics>, ({String farmId, DateRange range})>(
        (ref, params) async {
  final received = await ref
      .read(feedRepositoryProvider)
      .getAllReceived(
        farmId: params.farmId,
        fromDate: params.range.from,
        toDate: params.range.to,
      );

  return SupplierAnalytics.calculateFromFeed(
    received: received,
    range: params.range,
  );
});

final costPerEggProvider = FutureProvider.autoDispose
    .family<CostPerEgg, ({String farmId, DateRange range})>(
        (ref, params) async {
  final received = await ref
      .read(feedRepositoryProvider)
      .getAllReceived(
        farmId: params.farmId,
        fromDate: params.range.from,
        toDate: params.range.to,
      );
  final expenses = await ref.read(expenseRepositoryProvider).getExpenses(
    farmId: params.farmId,
    fromDate: params.range.from,
    toDate: params.range.to,
  );
  final eggs = await ref.read(eggProductionRepositoryProvider).getAllRecords(
    farmId: params.farmId,
    fromDate: params.range.from,
    toDate: params.range.to,
  );

  return CostPerEgg.calculate(
    feedReceived: received,
    expenses: expenses,
    eggs: eggs,
    range: params.range,
  );
});

final dailyTrendProvider = FutureProvider.autoDispose
    .family<List<DailyTrend>, ({String farmId, DateRange range})>(
        (ref, params) async {
  final eggs = await ref.read(eggProductionRepositoryProvider).getAllRecords(
    farmId: params.farmId,
    fromDate: params.range.from,
    toDate: params.range.to,
  );
  final mortality = await ref
      .read(mortalityRepositoryProvider)
      .getAllRecords(
        farmId: params.farmId,
        fromDate: params.range.from,
        toDate: params.range.to,
      );
  final consumption = await ref
      .read(feedRepositoryProvider)
      .getAllConsumption(
        farmId: params.farmId,
        fromDate: params.range.from,
        toDate: params.range.to,
      );

  return buildDailyTrend(
    eggs: eggs,
    mortality: mortality,
    feed: consumption,
    range: params.range,
  );
});

final flockPerformanceProvider = FutureProvider.autoDispose
    .family<
        FlockPerformance,
        ({
          FlockModel flock,
          DateRange range,
          double pricePerEgg,
        })>((ref, params) async {
  final farmId = params.flock.farmId;
  final eggs =
      await ref.read(eggProductionRepositoryProvider).getAllRecords(farmId: farmId);
  final mortality = await ref
      .read(mortalityRepositoryProvider)
      .getAllRecords(farmId: farmId);
  final feedConsumption = await ref
      .read(feedRepositoryProvider)
      .getAllConsumption(farmId: farmId);
  final feedReceived = await ref
      .read(feedRepositoryProvider)
      .getAllReceived(farmId: farmId);
  final dispatches =
      await ref.read(dispatchRepositoryProvider).getAll(farmId: farmId);
  final payments =
      await ref.read(paymentRepositoryProvider).getAll(farmId: farmId);
  final expenses = await ref
      .read(expenseRepositoryProvider)
      .getExpenses(farmId: farmId);

  // P0: Fetch opening balance for this flock
  final openingBalance = await ref
      .read(openingBalanceRepositoryProvider)
      .getForFlock(farmId, params.flock.id);

  return FlockPerformance.calculate(
    flock: params.flock,
    eggs: eggs,
    mortality: mortality,
    feedConsumption: feedConsumption,
    feedReceived: feedReceived,
    dispatches: dispatches,
    payments: payments,
    expenses: expenses,
    range: params.range,
    pricePerEgg: params.pricePerEgg,
    openingBalance: openingBalance,
  );
});
