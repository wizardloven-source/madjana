import 'package:core/core.dart';
import 'package:data/src/datasources/remote/supabase_partnership_datasource.dart';
import 'package:data/src/repositories/partnership_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_supabase_api.dart';

void main() {
  late FakeSupabaseApi fake;
  late SupabasePartnershipDatasource ds;

  setUp(() {
    fake = FakeSupabaseApi();
    ds = SupabasePartnershipDatasource(fake);
  });

  group('SupabasePartnershipDatasource — عقد معاينة التوزيع', () {
    test('calculateDistribution يستدعي الدالة بالمعاملات والفلتر الصحيحين',
        () async {
      fake.onRpc = (_, __) => [];

      await ds.calculateDistribution(
        farmId: 'farm-1',
        periodStart: DateTime(2026, 10, 1),
        periodEnd: DateTime(2026, 10, 31),
      );

      final call = fake.calls
          .firstWhere((c) => c.startsWith('rpc calculate_profit_distribution '));
      expect(call.contains('"p_farm_id":"farm-1"'), isTrue);
      expect(call.contains('"p_period_start":"2026-10-01"'), isTrue);
      expect(call.contains('"p_period_end":"2026-10-31"'), isTrue);
      expect(call.contains('"p_flock_id":null'), isTrue);
    });

    test('يمرّر p_flock_id عند تحديد قطيع', () async {
      fake.onRpc = (_, __) => [];

      await ds.calculateDistribution(
        farmId: 'farm-1',
        periodStart: DateTime(2026, 10, 1),
        periodEnd: DateTime(2026, 10, 31),
        flockId: 'flock-9',
      );

      final call = fake.calls.last;
      expect(call.contains('"p_flock_id":"flock-9"'), isTrue);
    });

    test('يحلّل الصفوف إلى نموذج المعاينة', () async {
      fake.onRpc = (_, __) => [
            {
              'partner_id': 'p1',
              'share_type': 'percentage',
              'share_value': 25,
              'amount': 250.5,
            },
            {
              'partner_id': 'p2',
              'share_type': 'salary',
              'share_value': 500,
              'amount': 500,
            },
          ];

      final rows = await ds.calculateDistribution(
        farmId: 'farm-1',
        periodStart: DateTime(2026, 10, 1),
        periodEnd: DateTime(2026, 10, 31),
      );

      expect(rows, hasLength(2));
      expect(rows[0].partnerId, 'p1');
      expect(rows[0].shareType, ShareModel.percentage);
      expect(rows[0].shareValue, 25);
      expect(rows[0].amount, 250.5);
      expect(rows[1].shareType, ShareModel.salary);
    });

    test('يُعيد قائمة فارغة عندما لا تُرجع الدالة شيئاً', () async {
      fake.onRpc = (_, __) => null;
      final rows = await ds.calculateDistribution(
        farmId: 'farm-1',
        periodStart: DateTime(2026, 10, 1),
        periodEnd: DateTime(2026, 10, 31),
      );
      expect(rows, isEmpty);
    });
  });

  group('PartnerModel like — نموذج المعاينة', () {
    test('fromJson يوزّع القيم الافتراضية ويتعامل مع الأعداد النصية', () {
      final p = ProfitDistributionPreview.fromJson({
        'partner_id': 'p1',
        'share_type': 'shares',
        'share_value': '300.5',
        'amount': '150.25',
      });
      expect(p.shareType, ShareModel.shares);
      expect(p.shareValue, 300.5);
      expect(p.amount, 150.25);
    });

    test('fromJson بلا نوع معروف يعود إلى percentage والمبلغ صفر', () {
      final p = ProfitDistributionPreview.fromJson({'partner_id': 'p1'});
      expect(p.shareType, ShareModel.percentage);
      expect(p.shareValue, isNull);
      expect(p.amount, 0);
    });
  });

  group('PartnershipRepositoryImpl — ترجمة الأخطاء', () {
    test('يغلّف خطأ الدالة برسالة الاستثناء الحقيقية', () async {
      fake.onRpc = (_, __) => throw Exception('AUTHORIZATION_DENIED');
      final repo = PartnershipRepositoryImpl(remoteDatasource: ds);

      await expectLater(
        repo.calculateDistribution(
          farmId: 'farm-1',
          periodStart: DateTime(2026, 10, 1),
          periodEnd: DateTime(2026, 10, 31),
        ),
        throwsA(predicate(
            (e) => e.toString().contains('AUTHORIZATION_DENIED'))),
      );
    });
  });

  group('SupabasePartnershipDatasource — إنشاء/اعتماد التوزيع (W7.3)', () {
    test('createDistribution يستدعي create_profit_distribution بكل p_*',
        () async {
      fake.onRpc = (_, __) => 'dist-uuid-1';

      final id = await ds.createDistribution(
        farmId: 'farm-1',
        periodStart: DateTime(2026, 10, 1),
        periodEnd: DateTime(2026, 10, 31),
        reserveAmount: 300,
        label: 'Q3',
      );

      expect(id, 'dist-uuid-1');
      final call = fake.calls
          .firstWhere((c) => c.startsWith('rpc create_profit_distribution '));
      expect(call.contains('"p_farm_id":"farm-1"'), isTrue);
      expect(call.contains('"p_period_start":"2026-10-01"'), isTrue);
      expect(call.contains('"p_period_end":"2026-10-31"'), isTrue);
      expect(call.contains('"p_flock_id":null'), isTrue);
      expect(call.contains('"p_reserve_amount":300.0'), isTrue);
      expect(call.contains('"p_label":"Q3"'), isTrue);
      expect(call.contains('"p_notes":null'), isTrue);
    });

    test('createDistribution يمرّر القطيع عندما يُحدَّد', () async {
      fake.onRpc = (_, __) => 'dist-uuid-2';

      await ds.createDistribution(
        farmId: 'farm-1',
        periodStart: DateTime(2026, 10, 1),
        periodEnd: DateTime(2026, 10, 31),
        flockId: 'flock-9',
      );

      expect(fake.lastCall.contains('"p_flock_id":"flock-9"'), isTrue);
    });

    test('approveDistribution يستدعي approve_profit_distribution بالمعرّف',
        () async {
      fake.onRpc = (_, __) => null;

      await ds.approveDistribution(distributionId: 'dist-7');

      expect(fake.lastCall,
          'rpc approve_profit_distribution {"p_distribution_id":"dist-7"}');
    });

    test('يترجم رسائل PostgREST إلى SyncFailure بكود واضح', () async {
      const cases = {
        'AUTHORIZATION_DENIED: only system_admin may approve a distribution':
            'AUTHORIZATION_DENIED',
        'DISTRIBUTION_EXISTS: a distribution already exists for farm':
            'DISTRIBUTION_EXISTS',
        'NEGATIVE_NET_PROFIT: period net profit is -5000':
            'NEGATIVE_NET_PROFIT',
        'INVALID_RESERVE: reserve_amount must be >= 0': 'INVALID_RESERVE',
        'INVALID_STATUS_TRANSITION: approved -> approved':
            'INVALID_STATUS_TRANSITION',
        'FLOCK_FARM_MISMATCH: flock does not belong to farm':
            'FLOCK_FARM_MISMATCH',
        'FLOCK_NOT_FOUND: ffffffff-0000': 'FLOCK_NOT_FOUND',
        'NO_SESSION: approve_profit_distribution requires an authenticated caller':
            'NO_SESSION',
      };

      for (final entry in cases.entries) {
        fake.onRpc = (_, __) => throw _FakePostgrestError(entry.key);
        await expectLater(
          ds.createDistribution(
            farmId: 'farm-1',
            periodStart: DateTime(2026, 10, 1),
            periodEnd: DateTime(2026, 10, 31),
          ),
          throwsA(isA<SyncFailure>()
              .having((e) => e.code, 'code', entry.value)
              .having((e) => e.message, 'message', contains(entry.value))),
        );
      }
    });

    test('الكود المجهول يصير UNKNOWN بدل رمي نصّ عام', () async {
      fake.onRpc = (_, __) => throw _FakePostgrestError('something exploded');

      await expectLater(
        ds.approveDistribution(distributionId: 'dist-1'),
        throwsA(isA<SyncFailure>()
            .having((e) => e.code, 'code', 'UNKNOWN')
            .having((e) => e.message, 'message', contains('something exploded'))),
      );
    });
  });

  group('PartnershipRepositoryImpl — إنشاء/اعتماد', () {
    test('ينشر SyncFailure من المصدر دون لفّه في Exception', () async {
      final repo = PartnershipRepositoryImpl(remoteDatasource: ds);
      fake.onRpc =
          (_, __) => throw _FakePostgrestError('AUTHORIZATION_DENIED: only system_admin');

      await expectLater(
        repo.approveDistribution(distributionId: 'dist-1'),
        throwsA(isA<SyncFailure>()
            .having((e) => e.code, 'code', 'AUTHORIZATION_DENIED')),
      );
    });
  });
}

/// يحاكي PostgrestException: يحمل getter ‏`message` الذي يقرأه التحويل.
class _FakePostgrestError implements Exception {
  final String message;
  _FakePostgrestError(this.message);

  @override
  String toString() => 'PostgrestException(message: $message, code: P0001)';
}
