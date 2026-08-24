import 'package:test/test.dart';
import 'package:core/core.dart';

void main() {
  group('EggCalculator', () {
    test('calculateTotal - حساب صحيح', () {
      final total = EggCalculator.calculateTotal(
        cartons: 2,
        trays: 5,
        looseEggs: 10,
      );
      // (2 × 360) + (5 × 30) + 10 = 720 + 150 + 10 = 880
      expect(total, 880);
    });

    test('normalize - تحويل بيضات زائدة إلى صحون', () {
      final result = EggCalculator.normalize(
        cartons: 0,
        trays: 0,
        looseEggs: 45,
      );
      expect(result.cartons, 0);
      expect(result.trays, 1); // 45 ÷ 30 = 1 صحن
      expect(result.looseEggs, 15); // 45 % 30 = 15
    });

    test('normalize - تحويل صحون زائدة إلى كراتين', () {
      final result = EggCalculator.normalize(
        cartons: 0,
        trays: 15,
        looseEggs: 0,
      );
      expect(result.cartons, 1); // 15 ÷ 12 = 1 كرتون
      expect(result.trays, 3); // 15 % 12 = 3
    });

    test('normalize - تحويل كامل', () {
      final result = EggCalculator.normalize(
        cartons: 1,
        trays: 14,
        looseEggs: 35,
      );
      // 35 بيضة → 1 صحن + 5 بيضات
      // 14 + 1 = 15 صحن → 1 كرتون + 3 صحون
      // 1 + 1 = 2 كرتون
      expect(result.cartons, 2);
      expect(result.trays, 3);
      expect(result.looseEggs, 5);
    });

    test('kgToBags - تحويل صحيح', () {
      expect(EggCalculator.kgToBags(48), 2.0);
      expect(EggCalculator.kgToBags(24), 1.0);
    });

    test('tonsToKg - تحويل صحيح', () {
      expect(EggCalculator.tonsToKg(2), 2000);
      expect(EggCalculator.tonsToKg(0.5), 500);
    });
  });

  group('Formatters', () {
    test('formatDate - تنسيق صحيح', () {
      final date = DateTime(2026, 8, 19);
      expect(Formatters.formatDate(date), '19/08/2026');
    });

    test('formatNumber - فاصل الآلاف', () {
      expect(Formatters.formatNumber(1234567), '1,234,567');
    });

    test('formatWeight - تنسيق الوزن', () {
      expect(Formatters.formatWeight(24.5), '24.50 كغ');
    });
  });
}