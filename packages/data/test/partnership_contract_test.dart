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

  group('SupabasePartnershipDatasource — قراءة رأس التوزيع (W7.3-UI)', () {
    test('getDistribution يستعلم profit_distributions بفلاتر المزرعة/الفترة',
        () async {
      fake.seed('profit_distributions', [
        {
          'id': 'd-1',
          'farm_id': 'farm-1',
          'flock_id': null,
          'period_start': '2026-10-01',
          'period_end': '2026-10-31',
          'status': 'draft',
          'total_revenue': 2000,
          'total_expenses': 500,
          'net_profit': 1500,
          'reserve_amount': 300,
          'distributable_profit': 1200,
          'created_at': '2026-10-31T00:00:00Z',
        },
      ]);

      final d = await ds.getDistribution(
        farmId: 'farm-1',
        periodStart: DateTime(2026, 10, 1),
        periodEnd: DateTime(2026, 10, 31),
      );

      expect(d, isNotNull);
      expect(d!.id, 'd-1');
      expect(d.status, ProfitDistributionStatus.draft);
      expect(d.isDraft, isTrue);
      expect(d.netProfit, 1500);
      expect(d.distributableProfit, 1200);
      expect(fake.findCall('select profit_distributions'), isTrue);
      expect(fake.findCall('eq farm_id=farm-1'), isTrue);
      expect(fake.findCall('eq period_start=2026-10-01'), isTrue);
      expect(fake.findCall('eq period_end=2026-10-31'), isTrue);
    });

    test('getDistribution يُعيد null عندما لا يوجد رأس للفترة', () async {
      final d = await ds.getDistribution(
        farmId: 'farm-1',
        periodStart: DateTime(2026, 10, 1),
        periodEnd: DateTime(2026, 10, 31),
      );
      expect(d, isNull);
    });

    test('getDistribution يختار رأس القطيع المحدد لا رأس المزرعة', () async {
      fake.seed('profit_distributions', [
        {
          'id': 'whole-farm',
          'farm_id': 'farm-1',
          'flock_id': null,
          'period_start': '2026-10-01',
          'period_end': '2026-10-31',
          'status': 'draft',
          'created_at': '2026-10-31T00:00:00Z',
        },
        {
          'id': 'flock-9-row',
          'farm_id': 'farm-1',
          'flock_id': 'flock-9',
          'period_start': '2026-10-01',
          'period_end': '2026-10-31',
          'status': 'approved',
          'created_at': '2026-10-31T00:00:00Z',
        },
      ]);

      final d = await ds.getDistribution(
        farmId: 'farm-1',
        periodStart: DateTime(2026, 10, 1),
        periodEnd: DateTime(2026, 10, 31),
        flockId: 'flock-9',
      );

      expect(d!.id, 'flock-9-row');
      expect(d.status, ProfitDistributionStatus.approved);
    });
  });

  group('ProfitDistribution — نموذج الرأس', () {
    test('fromJson يقرأ الحالة والأرقام النصية والتواريخ', () {
      final d = ProfitDistribution.fromJson({
        'id': 'd1',
        'farm_id': 'f1',
        'flock_id': null,
        'period_start': '2026-10-01',
        'period_end': '2026-10-31',
        'status': 'approved',
        'total_revenue': '2000',
        'total_expenses': '500',
        'net_profit': '1500',
        'reserve_amount': 300,
        'distributable_profit': '1200',
        'approved_at': '2026-11-01T09:00:00Z',
      });

      expect(d.status, ProfitDistributionStatus.approved);
      expect(d.isDraft, isFalse);
      expect(d.netProfit, 1500);
      expect(d.reserveAmount, 300);
      expect(d.periodStart, DateTime(2026, 10, 1));
      expect(d.approvedAt, isNotNull);
    });

    test('fromJson بحالة غير معروفة يعود إلى draft', () {
      final d = ProfitDistribution.fromJson(
          {'id': 'x', 'farm_id': 'f', 'status': 'bogus'});
      expect(d.status, ProfitDistributionStatus.draft);
      expect(d.netProfit, 0);
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
