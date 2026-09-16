import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// Phase 1 Analytics Providers — Mobile

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

  return ProductionKpi.calculate(
    records: eggs,
    range: params.range,
    totalBirds: totalBirds,
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

final stockAlertsProvider = FutureProvider.autoDispose
    .family<List<StockAlert>, String>((ref, farmId) async {
  final items = await ref.read(inventoryRepositoryProvider).getItems(farmId);
  return StockAlert.calculate(items: items);
});
