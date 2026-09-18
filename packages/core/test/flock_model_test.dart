import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  FlockModel _flock({int initial = 5300, int current = 5270}) {
    return FlockModel(
      id: 'flock-1',
      farmId: 'farm-1',
      breed: 'هاي لاين بروان',
      startDate: DateTime(2025, 12, 18),
      initialCount: initial,
      currentCount: current,
    );
  }

  group('FlockModel.effectiveCurrentCount — أرقام بطاقة القطيع', () {
    test('يصلح القيمة القديمة الفاسدة: 5300 أولي، نفوق 1460 + 13 → 3827', () {
      final flock = _flock(current: 5270);
      final effective = flock.effectiveCurrentCount(
        openingMortality: 1460,
        dailyMortality: 13,
      );
      expect(effective, 3827);
    });

    test('لا يُضاعف العدد الأولي من الأرصدة الافتتاحية', () {
      final flock = _flock(initial: 5300);
      expect(flock.initialCount, 5300);
    });

    test('يحافظ على خصم شرعي مخزَّن (بيع طيور حية) أقل من السقف', () {
      final flock = _flock(current: 3800);
      final effective = flock.effectiveCurrentCount(
        openingMortality: 1460,
        dailyMortality: 13,
      );
      expect(effective, 3800);
    });

    test('يحدّ النتيجة إلى الصفر وليس إلى قيمة سالبة', () {
      final flock = _flock(current: 50, initial: 100);
      final effective = flock.effectiveCurrentCount(
        openingMortality: 90,
        dailyMortality: 20,
      );
      expect(effective, 0);
    });

    test('بلا نفوق: السقف = العدد الأولي', () {
      final flock = _flock(current: 5270);
      final effective = flock.effectiveCurrentCount(
        openingMortality: 0,
        dailyMortality: 0,
      );
      expect(effective, 5270);
    });
  });

  group('FlockModel.effectiveCount — أحادي المصدر للعدد الفعلي', () {
    test('يساوي مجموع النفوق (الافتتاحي + اليومي)', () {
      final flock = _flock(current: 5270);
      expect(flock.effectiveCount(1460 + 13), 3827);
    });

    test('يحافظ على المخزَّن عند عدم تجاوز السقف', () {
      final flock = _flock(current: 3800);
      expect(flock.effectiveCount(1473), 3800);
    });

    test('يحدّ النتيجة إلى الصفر', () {
      final flock = _flock(current: 50, initial: 100);
      expect(flock.effectiveCount(120), 0);
    });
  });

  group('FlockModel.copyWith — العدد الحالي', () {
    test('ينسخ القيمة الجديدة فقط ويحافظ على البقية', () {
      final flock = _flock();
      final updated = flock.copyWith(currentCount: 4000);
      expect(updated.currentCount, 4000);
      expect(updated.initialCount, flock.initialCount);
      expect(updated.id, flock.id);
    });

    test('بدون وسيط يُبقي القيمة كما هي', () {
      final flock = _flock();
      final updated = flock.copyWith();
      expect(updated.currentCount, flock.currentCount);
      expect(updated.toJson()['current_count'], flock.currentCount);
    });
  });
}