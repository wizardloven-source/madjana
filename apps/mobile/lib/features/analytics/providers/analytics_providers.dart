import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// Phase 1 Analytics Providers — Mobile

/// العدد "الفعلي" لكل قطيع = min(المخزَّن، الأولي − مجموع النفوق الكلي).
/// لا يُغيّر البيانات المخزنة؛ يُستخدم لعرض العدد الحقيقي في كل الشاشات.
final effectiveFlockCountsProvider = FutureProvider.autoDispose
    .family<Map<String, int>, String>((ref, farmId) async {
  final flocks =
      await ref.read(flockRepositoryProvider).getFlocks(farmId);
  final mortality = await ref
      .read(mortalityRepositoryProvider)
      .getAllRecords(farmId: farmId);
  final totals = <String, int>{};
  for (final m in mortality) {
    totals[m.flockId] = (totals[m.flockId] ?? 0) + m.count;
  }
  return {
    for (final f in flocks)
      f.id: f.effectiveCount(totals[f.id] ?? 0),
  };
});

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
  final counts = await ref
      .watch(effectiveFlockCountsProvider(params.farmId).future);
  final totalBirds = flocks
      .where((f) => f.status == FlockStatus.active)
      .fold<int>(0, (s, f) => s + (counts[f.id] ?? f.currentCount));

  // م11: وضع «فترة» يُصفِّر الأرصدة الافتتاحية؛ وضع «تراكمي» يحسبها كاملة.
  final openingBalances =
      await ref.read(openingBalanceRepositoryProvider).getForFarm(params.farmId);
  final openingEggsTotal = params.range.mode == ReportMode.cumulative
      ? openingBalances.fold<int>(0, (s, b) => s + b.eggsProduced)
      : 0;

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
  final counts = await ref
      .watch(effectiveFlockCountsProvider(params.farmId).future);
  final totalBirds = flocks
      .where((f) => f.status == FlockStatus.active)
      .fold<int>(0, (s, f) => s + (counts[f.id] ?? f.currentCount));

  // م11: P0 opening-balance mortality — صفر عند «فترة»، كاملة عند «تراكمي».
  final openingBalances =
      await ref.read(openingBalanceRepositoryProvider).getForFarm(params.farmId);
  final openingMortalityTotal = params.range.mode == ReportMode.cumulative
      ? openingBalances.fold<int>(0, (s, b) => s + b.mortalityCount)
      : 0;

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
  final counts = await ref
      .watch(effectiveFlockCountsProvider(params.farmId).future);
  final totalBirds = flocks
      .where((f) => f.status == FlockStatus.active)
      .fold<int>(0, (s, f) => s + (counts[f.id] ?? f.currentCount));

  return FeedKpi.calculate(
    consumption: consumption,
    received: received,
    range: params.range,
    totalBirds: totalBirds,
    currentStockKg: params.stockKg,
  );
});

final stockAlertsProvider = FutureProvider.autoDispose
    .family<List<StockAlert>, String>((ref, farmId) async {
  final items = await ref.read(inventoryRepositoryProvider).getItems(farmId);
  return StockAlert.calculate(items: items);
});
