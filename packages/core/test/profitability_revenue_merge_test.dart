import 'package:test/test.dart';
import 'package:core/core.dart';

///WHY
///
/// يوجد نظامان منفصلان للإيراد في المشروع:
///   - `payments`  : فواتير بيع البيض (تُفتح صفراً عند كل تخريج)
///   - `revenue`   : إيراد يدوي غير البيض (دجاج حي، أبنية، معدات، أخرى)
///
/// الربحية كانت تقرأ `payments` وحدها، فإيراد الدجاج الحي والأبنية كان
/// مسجلاً في قاعدة البيانات لكنه غائب عن كل تقرير ربحية. هذه الاختبارات
/// تثبّت السلوك الصحيح: يُضاف الإيراد غير البيض، ولا يُضاعف بيض.
void main() {
  final range = DateRange.thisMonth();
  final inRange = range.from.add(const Duration(days: 1));
  final outOfRange = range.from.subtract(const Duration(days: 40));

  DispatchModel dispatch(String id) => DispatchModel(
        id: id,
        farmId: 'f1',
        date: inRange,
        customerId: 'c1',
        cartons: 10,
        trays: 0,
        workerId: 'w1',
      );

  PaymentModel payment({
    required String dispatchId,
    double totalDue = 0,
    double amountPaid = 0,
    DateTime? date,
  }) =>
      PaymentModel(
        farmId: 'f1',
        dispatchId: dispatchId,
        customerId: 'c1',
        date: date ?? inRange,
        pricePerCarton: 10,
        totalDue: totalDue,
        amountPaid: amountPaid,
        paymentMethod: PaymentMethod.cash,
        managerId: 'm1',
      );

  RevenueModel revenue({
    required RevenueCategory category,
    double amount = 100,
    DateTime? date,
  }) =>
      RevenueModel(
        farmId: 'f1',
        date: date ?? inRange,
        category: category,
        amount: amount,
      );

  group('FarmProfitability — دمج إيراد غير البيض', () {
    FarmProfitability calc(
      List<RevenueModel> other, {
      List<PaymentModel>? pays,
    }) =>
        FarmProfitability.calculate(
          dispatches: [dispatch('d1')],
          payments: pays ??
              [payment(dispatchId: 'd1', totalDue: 500, amountPaid: 500)],
          feedReceived: const [],
          expenses: const [],
          range: range,
          otherRevenue: other,
        );

    test('يُضيف الإيراد غير البيض إلى الإيراد الكلي', () async {
      final r = calc([
        revenue(category: RevenueCategory.liveChicken, amount: 250),
        revenue(category: RevenueCategory.building, amount: 100),
      ]);
      // 500 بيض + 350 غير بيض
      expect(r.revenue, 350 + 500);
      expect(r.otherRevenue, 350);
      expect(r.margin, 850); // بلا تكاليف
    });

    test('لا يضاعف بيع البيض: eggSales مستثناة', () async {
      final r = calc([
        revenue(category: RevenueCategory.eggSales, amount: 9999),
      ]);
      // لو حُسب eggSales لأصبح الإيراد 10499 — وهذا تضخيم صريح
      expect(r.revenue, 500);
      expect(r.otherRevenue, 0);
    });

    test('يتجاهل الإيراد خارج الفترة', () async {
      final r = calc([
        revenue(
          category: RevenueCategory.equipment,
          amount: 777,
          date: outOfRange,
        ),
      ]);
      expect(r.revenue, 500);
      expect(r.otherRevenue, 0);
    });

    test('المستحق يبقى من فواتير البيض فقط', () async {
      final r = calc(
        [revenue(category: RevenueCategory.liveChicken, amount: 300)],
        pays: [payment(dispatchId: 'd1', totalDue: 500, amountPaid: 200)],
      );
      // إيراد غير البيض ليس ديناً على زبون، فلا يدخل outstanding
      expect(r.outstanding, 300);
    });
  });

  group('FinancialKpi — دمج إيراد غير البيض', () {
    test('يضيف الإيراد غير البيض إلى المبيعات والهامش', () async {
      final k = FinancialKpi.calculate(
        dispatches: [dispatch('d1')],
        payments: [payment(dispatchId: 'd1', totalDue: 500, amountPaid: 500)],
        expenses: const [],
        range: range,
        otherRevenue: [
          revenue(category: RevenueCategory.other, amount: 150),
        ],
      );
      expect(k.totalSales, 650);
      expect(k.otherRevenue, 150);
      expect(k.estimatedMargin, 650);
    });

    test('لا يضاعف بيض عبر eggSales', () async {
      final k = FinancialKpi.calculate(
        dispatches: [dispatch('d1')],
        payments: [payment(dispatchId: 'd1', totalDue: 500, amountPaid: 500)],
        expenses: const [],
        range: range,
        otherRevenue: [
          revenue(category: RevenueCategory.eggSales, amount: 9999),
        ],
      );
      expect(k.totalSales, 500);
      expect(k.otherRevenue, 0);
    });
  });
}
