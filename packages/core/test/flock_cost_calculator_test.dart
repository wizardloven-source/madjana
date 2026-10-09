import 'package:test/test.dart';
import 'package:core/core.dart';

/// م12 — FlockCostCalculator
///
/// المعادلة (docs/ACCOUNTING_RULES.md §6):
///   flockCost(X) =
///       Σ expenses.amount          WHERE flock_id = X
///     + Σ feed_received.kg × price_per_kg WHERE flock_id = X
///     + Σ medications.cost         WHERE flock_id = X
///     + Σ stock_adjustments.delta_qty × unit_price WHERE flock_id = X
void main() {
  const flockId = 'fl1';
  final inRange = DateTime(2026, 10, 5);
  final periodRange = DateRange(
    from: DateTime(2026, 10, 1),
    to: DateTime(2026, 10, 10),
    label: 'فترة',
  );

  FlockModel flock(String id) => FlockModel(
        id: id,
        farmId: 'f1',
        breed: 'لحم',
        startDate: DateTime(2026, 1, 1),
        initialCount: 1000,
        currentCount: 1000,
      );

  FeedReceivedModel feed({
    String? flock = flockId,
    double kg = 100,
    double? price,
  }) =>
      FeedReceivedModel(
        farmId: 'f1',
        flockId: flock,
        date: inRange,
        entryMode: FeedEntryMode.kg,
        quantity: kg,
        quantityKg: kg,
        feedType: FeedType.layer,
        pricePerKg: price,
      );

  ExpenseModel expense({
    String? flock = flockId,
    double amount = 10,
    ExpenseCategory category = ExpenseCategory.other,
  }) =>
      ExpenseModel(
        farmId: 'f1',
        flockId: flock,
        date: inRange,
        category: category,
        amount: amount,
      );

  MedicationModel med({
    String? flock = flockId,
    double? cost,
    String? item,
  }) =>
      MedicationModel(
        farmId: 'f1',
        flockId: flock,
        date: inRange,
        type: MedicationType.drug,
        medicineName: 'دواء',
        dosage: '10mg',
        administrationRoute: AdministrationRoute.water,
        cost: cost,
        inventoryItemId: item,
        workerId: 'w1',
      );

  StockAdjustment adj({
    String? flock = flockId,
    double delta = -10,
    double? price,
  }) =>
      StockAdjustment(flockId: flock, deltaQty: delta, unitPrice: price);

  group('لا شيء = صفر بلا أخطاء', () {
    test('بيانات خالية → كل المركبات صفر وعدادات التسعير فارغة', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: const [],
        expenses: const [],
        medications: const [],
        stockAdjustments: const [],
      );
      expect(c.totalCost, 0);
      expect(c.feedCost, 0);
      expect(c.medicationCost, 0);
      expect(c.expensesCost, 0);
      expect(c.stockAdjustmentCost, 0);
      expect(c.unpricedShipments, 0);
      expect(c.unpricedMedications, 0);
      expect(c.unpricedAdjustments, 0);
    });
  });

  group('المصروفات تُنسب للقطيع بالاسم فقط (§1–§2)', () {
    test('مصروف مباشر واحد للقطيع يُحتسب', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: const [],
        expenses: [expense(amount: 150.5)],
        medications: const [],
        stockAdjustments: const [],
      );
      expect(c.expensesCost, closeTo(150.5, 1e-9));
      expect(c.totalCost, closeTo(150.5, 1e-9));
    });

    test('مصروف مزرعة flock_id=NULL لا يُحتسب (رواتب مثلًا)', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: const [],
        expenses: [
          expense(flock: null, amount: 900, category: ExpenseCategory.labor),
        ],
        medications: const [],
        stockAdjustments: const [],
      );
      expect(c.expensesCost, 0);
      expect(c.totalCost, 0);
    });

    test('مقدار سالب يُشبَّك صفراً (دفاعي)', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: const [],
        expenses: [expense(amount: -50)],
        medications: const [],
        stockAdjustments: const [],
      );
      expect(c.expensesCost, 0);
    });
  });

  group('العلف — كمية × سعر للسعر فقط (§3)', () {
    test('شحنة مسعّرة: quantity_kg × price_per_kg', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: [feed(kg: 200, price: 2.5)],
        expenses: const [],
        medications: const [],
        stockAdjustments: const [],
      );
      expect(c.feedCost, closeTo(500, 1e-9));
      expect(c.unpricedShipments, 0);
    });

    test('شحنة بلا سعر تُحصى ولا تُجمع — تنبيه مرئي', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: [feed(kg: 200), feed(kg: 10, price: 3)],
        expenses: const [],
        medications: const [],
        stockAdjustments: const [],
      );
      expect(c.feedCost, closeTo(30, 1e-9));
      expect(c.unpricedShipments, 1);
    });
  });

  group('الأدوية — أولوية §4: مخزون ← cost ← 0+تنبيه', () {
    test('cost صريح يُحتسب', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: const [],
        expenses: const [],
        medications: [med(cost: 60)],
        stockAdjustments: const [],
      );
      expect(c.medicationCost, closeTo(60, 1e-9));
      expect(c.unpricedMedications, 0);
    });

    test('inventory_item_id بسعر مخزون ← السعر يفوز حتى مع وجود cost', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: const [],
        expenses: const [],
        medications: [med(cost: 10, item: 'it1')],
        stockAdjustments: const [],
        inventoryUnitPrices: {'it1': 25.0},
      );
      expect(c.medicationCost, closeTo(25, 1e-9));
    });

    test('inventory_item_id بلا سعر مخزون ← يتراجع إلى cost (§4 rule 2)', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: const [],
        expenses: const [],
        medications: [med(cost: 7, item: 'it99')],
        stockAdjustments: const [],
        inventoryUnitPrices: const {'it1': 25.0},
      );
      expect(c.medicationCost, closeTo(7, 1e-9));
    });

    test('بلا cost وبلا سعر مخزون ← 0 + تنبيه unpricedMedications', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: const [],
        expenses: const [],
        medications: [med()],
        stockAdjustments: const [],
      );
      expect(c.medicationCost, 0);
      expect(c.unpricedMedications, 1);
    });
  });

  group('تسويات المخزون — delta_qty × unit_price (§5)', () {
    test('تسوية مسعّرة تُحتسب بعلامتها', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: const [],
        expenses: const [],
        medications: const [],
        stockAdjustments: [adj(delta: 12, price: 4)],
      );
      expect(c.stockAdjustmentCost, closeTo(48, 1e-9));
      expect(c.unpricedAdjustments, 0);
    });

    test('تسوية بلا unit_price — كمية بلا سعر ليست تكلفة', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: const [],
        expenses: const [],
        medications: const [],
        stockAdjustments: [adj(delta: 12), adj(delta: 2, price: 5)],
      );
      expect(c.stockAdjustmentCost, closeTo(10, 1e-9));
      expect(c.unpricedAdjustments, 1);
    });
  });

  group('المصادر الأربعة معًا', () {
    test('المجموع = علف + دواء + مصروف + تسوية', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: [feed(kg: 10, price: 2)],
        expenses: [expense(amount: 100)],
        medications: [med(cost: 50)],
        stockAdjustments: [adj(delta: -2, price: 10)],
      );
      expect(c.feedCost, closeTo(20, 1e-9));
      expect(c.expensesCost, closeTo(100, 1e-9));
      expect(c.medicationCost, closeTo(50, 1e-9));
      expect(c.stockAdjustmentCost, closeTo(-20, 1e-9));
      expect(c.totalCost, closeTo(150, 1e-9));
    });

    test('لا يُحتسب أي مصدر ينتمي لقطيع آخر', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: [feed(flock: 'other', kg: 999, price: 1)],
        expenses: [expense(flock: 'other', amount: 999)],
        medications: [med(flock: 'other', cost: 999)],
        stockAdjustments: [adj(flock: 'other', delta: 999, price: 1)],
      );
      expect(c.feedCost, 0);
      expect(c.expensesCost, 0);
      expect(c.medicationCost, 0);
      expect(c.stockAdjustmentCost, 0);
    });
  });

  group('الشروط الصارمة', () {
    test('لا تكلفة سالبة أبداً — تُشبَّك عند 0', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: [feed(kg: 100, price: 1)],
        expenses: const [],
        medications: const [],
        stockAdjustments: [adj(delta: -1000, price: 50)],
      );
      expect(c.stockAdjustmentCost, closeTo(-50000, 1e-9));
      expect(c.feedCost, closeTo(100, 1e-9));
      expect(c.totalCost, 0);
    });

    test('دقة 4 أرقام عشرية (NUMERIC(19,4))', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: [feed(kg: 1, price: 1 / 3)],
        expenses: const [],
        medications: const [],
        stockAdjustments: const [],
      );
      expect(c.feedCost, closeTo(0.3333, 1e-9));
    });

    test('totalCost يُقرَّب لـ 4 أرقام كذلك (0.666… → 0.6667)', () {
      final c = FlockCostCalculator.calculate(
        flockId: flockId,
        feedReceived: [feed(kg: 1, price: 1 / 3), feed(kg: 1, price: 1 / 3)],
        expenses: const [],
        medications: const [],
        stockAdjustments: const [],
      );
      expect(c.totalCost, closeTo(0.6667, 1e-9));
    });
  });

  group('تكامل FlockPerformance (م12)', () {
    test('costBreakdown يمتص المصروفات والأدوية والتسويات للقطيع', () {
      final r = FlockPerformance.calculate(
        flock: flock(flockId),
        eggs: const [],
        mortality: const [],
        feedConsumption: const [],
        feedReceived: [feed(kg: 10, price: 2)],
        dispatches: const [],
        payments: const [],
        expenses: [
          expense(amount: 100),
          expense(flock: null, amount: 900, category: ExpenseCategory.labor),
        ],
        medications: [med(cost: 50)],
        stockAdjustments: [adj(delta: -2, price: 10)],
        range: periodRange,
      );
      expect(r.costBreakdown.feedCost, closeTo(20, 1e-9));
      expect(r.costBreakdown.expensesCost, closeTo(100, 1e-9));
      expect(r.costBreakdown.medicationCost, closeTo(50, 1e-9));
      expect(r.costBreakdown.stockAdjustmentCost, closeTo(-20, 1e-9));
      expect(r.costBreakdown.totalCost, closeTo(150, 1e-9));
      expect(r.estimatedMargin, closeTo(-150, 1e-9)); // لا إيراد، تكلفة 150
    });
  });
}