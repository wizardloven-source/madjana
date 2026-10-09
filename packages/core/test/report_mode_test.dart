import 'package:test/test.dart';
import 'package:core/core.dart';

/// م11 — وضع التقرير (فترة / تراكمي)
///
/// «فترة» تعرض نشاط النطاق المحدد فقط (الأرصدة الافتتاحية تصفَّر).
/// «تراكمي» تضيف الأرصدة الافتتاحية كاملة بلا ترشيح بتاريخ الإنشاء.
void main() {
  final periodRange = DateRange(
    from: DateTime(2026, 10, 1),
    to: DateTime(2026, 10, 10),
    label: 'فترة',
  );
  final cumulativeRange = DateRange(
    from: DateTime(2026, 10, 1),
    to: DateTime(2026, 10, 10),
    label: 'تراكمي',
    mode: ReportMode.cumulative,
  );
  final inRange = DateTime(2026, 10, 5);
  final outOfRange = DateTime(2026, 9, 1);

  EggProductionModel egg(int cartons, {DateTime? date}) => EggProductionModel(
        farmId: 'f1',
        flockId: 'fl1',
        date: date ?? inRange,
        cartons: cartons,
        trays: 0,
        looseEggs: 0,
        workerId: 'w1',
      );
  // كرتونة = 360 بيضة (AppConstants.eggsPerCarton).

  MortalityModel mort(int count, {DateTime? date}) => MortalityModel(
        farmId: 'f1',
        flockId: 'fl1',
        date: date ?? inRange,
        count: count,
        reason: MortalityReason.unknown,
        workerId: 'w1',
      );

  // رصيد افتتاحي قديم — تاريخ إنشائه (2020) خارج النطاق عمداً.
  final legacyOpening = OpeningBalanceModel(
    id: 'ob1',
    farmId: 'f1',
    flockId: 'fl1',
    createdAt: DateTime(2020, 5, 1),
    eggsProduced: 500,
    mortalityCount: 8,
    feedConsumedKg: 150,
    initialBirds: 1000,
  );

  group('DateRange / ReportMode', () {
    test('الوضع الافتراضي للنطاقات القصيرة هو فترة', () {
      expect(periodRange.mode, ReportMode.period);
      expect(DateRange.last30Days().mode, ReportMode.period);
    });

    test('DateRange.all يُنشئ تراكمي (كامل)', () {
      expect(DateRange.all().mode, ReportMode.cumulative);
    });
  });

  group('ProductionKpi — م11', () {
    test('فترة: الأرصدة الافتتاحية تصفَّر (open_bal = 0)', () {
      final k = ProductionKpi.calculate(
        records: [egg(1)],
        range: periodRange,
        totalBirds: 1000,
        openingBalanceEggs: 500,
      );
      expect(k.totalEggs, 360); // 360 وليس 860
      expect(k.sellableEggs, 360);
      expect(k.brokenEggs, 0);
    });

    test('تراكمي: الأرصدة الافتتاحية تدخل كاملة', () {
      final k = ProductionKpi.calculate(
        records: [egg(1)],
        range: cumulativeRange,
        totalBirds: 1000,
        openingBalanceEggs: 500,
      );
      expect(k.totalEggs, 860);
      expect(k.sellableEggs, 860);
    });

    test('تراكمي لا يتأثر بتاريخ إنشاء الرصيد ولا يُدخل خارج النطاق', () {
      final k = ProductionKpi.calculate(
        records: [egg(1), egg(1, date: outOfRange)],
        range: cumulativeRange,
        totalBirds: 1000,
        openingBalanceEggs: 500,
      );
      // 360 داخل النطاق + 500 رصيد (أنشئ خارج النطاق وما زال يُحتسب)؛
      // خارج النطاق لم يُحتسب في سجلات الفترة.
      expect(k.totalEggs, 860);
      expect(k.daysWithData, 1);
    });

    test('productionRate ≤ 100% حتى مع رصيد افتتاحي', () {
      final k = ProductionKpi.calculate(
        records: [egg(1)],
        range: cumulativeRange,
        totalBirds: 1000,
        openingBalanceEggs: 500,
      );
      // النسبة من البيض اليومي فقط (360 ÷ (1000 × 10)) — لا يتجاوز 100%.
      expect(k.totalEggs, 860);
      expect(k.productionRate, lessThanOrEqualTo(100));
      expect(k.productionRate, closeTo(3.6, 0.001));
    });
  });

  group('MortalityKpi — م11', () {
    test('فترة: deathsByReason لا يحتوي opening_balance', () {
      final m = MortalityKpi.calculate(
        records: [mort(2)],
        range: periodRange,
        totalBirds: 1000,
        openingBalanceMortality: 8,
      );
      expect(m.totalDeaths, 2);
      expect(m.deathsByReason.containsKey('opening_balance'), isFalse);
      expect(m.deathsByReason['unknown'], 2);
    });

    test('تراكمي: النفوق الافتتاحي كامل ويُجمَّع تحت سببه', () {
      final m = MortalityKpi.calculate(
        records: [mort(2)],
        range: cumulativeRange,
        totalBirds: 1000,
        openingBalanceMortality: 8,
      );
      expect(m.totalDeaths, 10);
      expect(m.deathsByReason['opening_balance'], 8);
      expect(m.deathsByReason['unknown'], 2);
    });
  });

  group('FlockPerformance — م11', () {
    test('حُذف تقدير التكلفة (علف × سعر البيضة)', () {
      final flock = FlockModel(
        id: 'fl1',
        farmId: 'f1',
        breed: 'لحم',
        startDate: DateTime(2026, 1, 1),
        initialCount: 1000,
        currentCount: 1000,
      );
      final r = FlockPerformance.calculate(
        flock: flock,
        eggs: [egg(1)],
        mortality: [mort(2)],
        feedConsumption: const [],
        feedReceived: [
          FeedReceivedModel(
            farmId: 'f1',
            flockId: 'fl1',
            date: inRange,
            entryMode: FeedEntryMode.kg,
            quantity: 100,
            quantityKg: 100,
            feedType: FeedType.layer,
          ),
        ],
        dispatches: const [],
        payments: const [],
        expenses: const [],
        range: periodRange,
        pricePerEgg: 10, // كان سابقاً: 100 × 10 = 1000
      );
      expect(r.costBreakdown.totalCost, 0); // م11/م12: لا «علف × سعر بيضة»
      expect(r.costPerEgg, 0);
      expect(r.production.totalEggs, 360); // الوضع «فترة»: بلا رصيد افتتاحي
    });
  });

  test('الرصيد الافتتاحي فعلي تُستخدمه FlockPerformance في التراكمي', () {
    final flock = FlockModel(
      id: 'fl1',
      farmId: 'f1',
      breed: 'لحم',
      startDate: DateTime(2026, 1, 1),
      initialCount: 1000,
      currentCount: 1000,
    );
    final r = FlockPerformance.calculate(
      flock: flock,
      eggs: [egg(1)],
      mortality: [mort(2)],
      feedConsumption: const [],
      feedReceived: const [],
      dispatches: const [],
      payments: const [],
      expenses: const [],
      range: cumulativeRange,
      openingBalance: legacyOpening,
    );
    expect(r.production.totalEggs, 860);
    expect(r.mortality.totalDeaths, 10);
  });
}