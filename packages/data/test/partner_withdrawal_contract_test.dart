import 'package:core/core.dart';
import 'package:data/src/datasources/remote/supabase_withdrawal_datasource.dart';
import 'package:data/src/repositories/partner_withdrawal_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_supabase_api.dart';

void main() {
  late FakeSupabaseApi fake;
  late SupabaseWithdrawalDatasource ds;

  setUp(() {
    fake = FakeSupabaseApi();
    ds = SupabaseWithdrawalDatasource(fake);
  });

  Map<String, dynamic> withdrawalRow({
    String id = 'w-1',
    String status = 'pending',
  }) =>
      {
        'id': id,
        'partner_id': 'p1',
        'farm_id': 'f1',
        'distribution_id': null,
        'amount': 100,
        'currency': 'dollar',
        'status': status,
        'requested_at': '2026-10-01T08:00:00Z',
        'requested_by': 'u-worker',
        'reason': 'اشتغيل',
        'reviewed_at': null,
        'reviewed_by': null,
        'rejection_reason': null,
        'paid_at': null,
        'payment_method': null,
        'notes': null,
      };

  group('SupabaseWithdrawalDatasource — قراءة السحوبات', () {
    test('getWithdrawals يستعلم partner_withdrawals بالفلاتر والترتيب', () async {
      fake.seed('partner_withdrawals', [withdrawalRow()]);

      final rows = await ds.getWithdrawals(
        partnerId: 'p1',
        farmId: 'f1',
        status: PartnerWithdrawalStatus.pending,
      );

      expect(rows, hasLength(1));
      expect(rows.first.id, 'w-1');
      expect(rows.first.status, PartnerWithdrawalStatus.pending);
      expect(rows.first.isPending, isTrue);
      expect(fake.findCall('select partner_withdrawals'), isTrue);
      expect(fake.findCall('eq partner_id=p1'), isTrue);
      expect(fake.findCall('eq farm_id=f1'), isTrue);
      expect(fake.findCall('eq status=pending'), isTrue);
      expect(fake.findCall('order partner_withdrawals requested_at asc=false'),
          isTrue);
    });

    test('getWithdrawals بلا فلاتر يجلب الكل', () async {
      fake.seed('partner_withdrawals', [
        withdrawalRow(id: 'w-1'),
        withdrawalRow(id: 'w-2', status: 'paid'),
      ]);

      final rows = await ds.getWithdrawals();
      expect(rows, hasLength(2));
      expect(fake.findCall('eq partner_id='), isFalse);
    });

    test('fromJson يقرأ الأعداد النصية والتواريخ', () {
      final w = PartnerWithdrawal.fromJson({
        'id': 'w-9',
        'partner_id': 'p1',
        'farm_id': 'f1',
        'amount': '250.5',
        'status': 'approved',
        'requested_at': '2026-10-02T10:00:00Z',
        'requested_by': 'u1',
        'reviewed_by': 'u-admin',
      });

      expect(w.amount, 250.5);
      expect(w.status, PartnerWithdrawalStatus.approved);
      expect(w.isPending, isFalse);
      expect(w.requestedAt, DateTime.parse('2026-10-02T10:00:00Z'));
      expect(w.reviewedBy, 'u-admin');
    });

    test('fromJson بحالة غير معروفة يعود إلى pending', () {
      final w = PartnerWithdrawal.fromJson({
        'id': 'x',
        'partner_id': 'p',
        'farm_id': 'f',
        'requested_by': 'u',
        'status': 'bogus',
      });
      expect(w.status, PartnerWithdrawalStatus.pending);
      expect(w.amount, 0);
    });

    test('toJson لا يحمل requested_at ولا reviewed_at ولا paid_at ولا id', () {
      final json = PartnerWithdrawal.fromJson({
        ...withdrawalRow(status: 'approved'),
        'reviewed_at': '2026-10-03T09:00:00Z',
        'reviewed_by': 'u-admin',
        'paid_at': '2026-10-04T09:00:00Z',
      }).toJson();

      expect(json.containsKey('requested_at'), isFalse);
      expect(json.containsKey('reviewed_at'), isFalse);
      expect(json.containsKey('paid_at'), isFalse);
      expect(json.containsKey('id'), isFalse);
      expect(json['status'], 'approved');
      expect(json['reviewed_by'], 'u-admin');
      expect(json['requested_by'], 'u-worker');
    });
  });

  group('SupabaseWithdrawalDatasource — إنشاء سحب', () {
    test('createWithdrawal يخزّن pending ويعيد الصف دون كتابة requested_at',
        () async {
      fake.onRpc = (_, __) => null;

      final w = await ds.createWithdrawal(
        partnerId: 'p1',
        farmId: 'f1',
        amount: 75,
        requestedBy: 'u-worker',
        reason: 'اشتغيل',
      );

      expect(w.amount, 75);
      expect(w.status, PartnerWithdrawalStatus.pending);
      expect(fake.findCall('insert partner_withdrawals'), isTrue);
      final insertCall = fake.calls
          .firstWhere((c) => c.startsWith('insert partner_withdrawals '));
      expect(insertCall.contains('"status":"pending"'), isTrue);
      expect(insertCall.contains('"requested_by":"u-worker"'), isTrue);
      expect(insertCall.contains('"requested_at"'), isFalse);
      expect(fake.findCall('select partner_withdrawals'), isTrue);
    });

    test('createWithdrawal يترجم PARTNER_NOT_FOUND', () async {
      fake.failWrites = true;

      await expectLater(
        ds.createWithdrawal(
          partnerId: 'ghost',
          farmId: 'f1',
          amount: 10,
          requestedBy: 'u1',
        ),
        throwsA(isA<SyncFailure>()),
      );
    });
  });

  group('SupabaseWithdrawalDatasource — اعتماد عبر RPC (W7.4)', () {
    test('approveWithdrawal يستدعي approve_withdrawal بالمعاملين', () async {
      fake.onRpc = (_, __) => null;

      await ds.approveWithdrawal(withdrawalId: 'w-7', approverId: 'admin-1');

      expect(fake.lastCall,
          'rpc approve_withdrawal {"p_withdrawal_id":"w-7","p_approver_id":"admin-1"}');
    });

    test('يترجم INVALID_STATUS_TRANSITION من الخادم', () async {
      fake.onRpc =
          (_, __) => throw _FakePostgrestError('INVALID_STATUS_TRANSITION: paid -> approved');

      await expectLater(
        ds.approveWithdrawal(withdrawalId: 'w-7', approverId: 'a1'),
        throwsA(isA<SyncFailure>()
            .having((e) => e.code, 'code', 'INVALID_STATUS_TRANSITION')),
      );
    });
  });

  group('SupabaseWithdrawalDatasource — رفض/صرف/إلغاء', () {
    test('rejectWithdrawal يحدّث الحالة والسبب مع مرشّح pending', () async {
      fake.seed('partner_withdrawals', [withdrawalRow()]);

      await ds.rejectWithdrawal(
          withdrawalId: 'w-1', rejectionReason: 'نقص رصيد');

      expect(fake.findCall('update partner_withdrawals'), isTrue);
      expect(fake.findCall('eq id=w-1'), isTrue);
      expect(fake.findCall('eq status=pending'), isTrue);
      final updateCall = fake.calls
          .firstWhere((c) => c.startsWith('update partner_withdrawals '));
      expect(updateCall.contains('"status":"rejected"'), isTrue);
      expect(updateCall.contains('"rejection_reason":"نقص رصيد"'), isTrue);
    });

    test('rejectWithdrawal بسبب فارغ يرفع REJECTION_REASON_REQUIRED محلياً',
        () async {
      await expectLater(
        ds.rejectWithdrawal(withdrawalId: 'w-1', rejectionReason: '   '),
        throwsA(isA<SyncFailure>()
            .having((e) => e.code, 'code', 'REJECTION_REASON_REQUIRED')),
      );
      expect(fake.calls, isEmpty);
    });

    test('rejectWithdrawal بلا صف مطابق يرفع WITHDRAWAL_CONFLICT', () async {
      await expectLater(
        ds.rejectWithdrawal(
            withdrawalId: 'w-missing', rejectionReason: 'سبب'),
        throwsA(isA<SyncFailure>()
            .having((e) => e.code, 'code', 'WITHDRAWAL_CONFLICT')),
      );
    });

    test('markPaid يحدّث الحالة مع مرشّح approved', () async {
      fake.seed('partner_withdrawals',
          [withdrawalRow(status: 'approved')]);

      await ds.markPaid(withdrawalId: 'w-1', paymentMethod: 'cash');

      final updateCall = fake.calls
          .firstWhere((c) => c.startsWith('update partner_withdrawals '));
      expect(updateCall.contains('"status":"paid"'), isTrue);
      expect(updateCall.contains('"payment_method":"cash"'), isTrue);
      expect(fake.findCall('eq status=approved'), isTrue);
      // paid_at لا يُكتب من العميل — الخادم يختتمه (قيد CHECK).
      expect(updateCall.contains('"paid_at"'), isFalse);
    });

    test('markPaid بلا صف مطابق يرفع WITHDRAWAL_CONFLICT', () async {
      await expectLater(
        ds.markPaid(withdrawalId: 'w-1'),
        throwsA(isA<SyncFailure>()
            .having((e) => e.code, 'code', 'WITHDRAWAL_CONFLICT')),
      );
    });

    test('cancelWithdrawal يحدّث الحالة بلا مرشّح حالة (السلّم خادمي)',
        () async {
      fake.seed('partner_withdrawals', [withdrawalRow()]);

      await ds.cancelWithdrawal(withdrawalId: 'w-1', notes: 'إلغاء');

      final updateCall = fake.calls
          .firstWhere((c) => c.startsWith('update partner_withdrawals '));
      expect(updateCall.contains('"status":"cancelled"'), isTrue);
      expect(updateCall.contains('"notes":"إلغاء"'), isTrue);
      expect(updateCall.contains('eq status='), isFalse);
    });

    test('cancelWithdrawal بلا صف يرفع WITHDRAWAL_NOT_FOUND', () async {
      await expectLater(
        ds.cancelWithdrawal(withdrawalId: 'w-missing'),
        throwsA(isA<SyncFailure>()
            .having((e) => e.code, 'code', 'WITHDRAWAL_NOT_FOUND')),
      );
    });
  });

  group('SupabaseWithdrawalDatasource — سجل التدقيق (W7.4)', () {
    test('getPartnerAudit يستعلم partner_audit بالفلاتر والترتيب', () async {
      fake.seed('partner_audit', [
        {
          'id': 'a-1',
          'farm_id': 'f1',
          'partner_id': 'p1',
          'action': 'withdrawal_approved',
          'old_values': {'status': 'pending'},
          'new_values': {'status': 'approved'},
          'changed_by': 'u-admin',
          'changed_at': '2026-10-05T12:00:00Z',
          'notes': 'auto: partner_withdrawals trigger',
        },
      ]);

      final entries = await ds.getPartnerAudit(farmId: 'f1', partnerId: 'p1');

      expect(entries, hasLength(1));
      expect(entries.first.action, 'withdrawal_approved');
      expect(entries.first.isAuto, isTrue);
      expect(entries.first.newValues, {'status': 'approved'});
      expect(fake.findCall('select partner_audit'), isTrue);
      expect(fake.findCall('eq farm_id=f1'), isTrue);
      expect(fake.findCall('eq partner_id=p1'), isTrue);
      expect(
          fake.findCall('order partner_audit changed_at asc=false'), isTrue);
    });
  });

  group('SupabaseWithdrawalDatasource — ملخص الشريك', () {
    test('getPartnerSummary تستدعي partner_summary وتحلّل الصف', () async {
      fake.onRpc = (_, __) => [
            {
              'name': 'شريك',
              'share_model': 'percentage',
              'share_value': 10,
              'net_profit': 500,
              'pending': 100,
              'paid': 50,
            }
          ];

      final s = await ds.getPartnerSummary(partnerId: 'p1');

      expect(fake.lastCall, 'rpc partner_summary {"p_partner_id":"p1"}');
      expect(s.name, 'شريك');
      expect(s.netProfit, 500);
      expect(s.pending, 100);
      expect(s.paid, 50);
      expect(s.available, 350);
    });

    test('AUTHORIZATION_DENIED من RPC يُسقط إلى حساب مباشر من الجداول',
        () async {
      fake.onRpc = (name, _) {
        if (name == 'partner_summary') {
          throw _FakePostgrestError('AUTHORIZATION_DENIED: not owner');
        }
        return null;
      };
      fake.seed('partners', [
        {
          'id': 'p1',
          'name': 'شريك المدير',
          'share_model': 'percentage',
          'percentage': 20,
          'shares': null,
          'salary_amount': null,
        },
      ]);
      fake.seed('profit_distributions', [
        {'id': 'd-approved', 'status': 'approved'},
        {'id': 'd-draft', 'status': 'draft'},
      ]);
      fake.seed('profit_distribution_details', [
        {'distribution_id': 'd-approved', 'partner_id': 'p1', 'profit_share': 300},
        {'distribution_id': 'd-approved', 'partner_id': 'p1', 'profit_share': 100},
        {'distribution_id': 'd-draft', 'partner_id': 'p1', 'profit_share': 999},
      ]);
      fake.seed('partner_withdrawals', [
        {'partner_id': 'p1', 'status': 'pending', 'amount': 40},
        {'partner_id': 'p1', 'status': 'approved', 'amount': 30},
        {'partner_id': 'p1', 'status': 'paid', 'amount': 20},
        {'partner_id': 'p1', 'status': 'rejected', 'amount': 777},
        {'partner_id': 'p1', 'status': 'cancelled', 'amount': 888},
      ]);

      final s = await ds.getPartnerSummary(partnerId: 'p1');

      expect(s.name, 'شريك المدير');
      expect(s.shareValue, 20);
      // بنود التوزيعات المعتمدة فقط (لا d-draft).
      expect(s.netProfit, 400);
      expect(s.pending, 70);
      expect(s.paid, 20);
    });

    test('PARTNER_NOT_FOUND من RPC يرمى كـ SyncFailure دون حساب بديل', () async {
      fake.onRpc =
          (_, __) => throw _FakePostgrestError('PARTNER_NOT_FOUND: ghost');

      await expectLater(
        ds.getPartnerSummary(partnerId: 'ghost'),
        throwsA(isA<SyncFailure>()
            .having((e) => e.code, 'code', 'PARTNER_NOT_FOUND')),
      );
      expect(fake.findCall('select partners'), isFalse);
    });

    test('حساب بديل بلا صف شريك يرفع PARTNER_NOT_FOUND', () async {
      fake.onRpc = (name, _) {
        if (name == 'partner_summary') {
          throw _FakePostgrestError('AUTHORIZATION_DENIED: not owner');
        }
        return null;
      };

      await expectLater(
        ds.getPartnerSummary(partnerId: 'ghost'),
        throwsA(isA<SyncFailure>()
            .having((e) => e.code, 'code', 'PARTNER_NOT_FOUND')),
      );
    });
  });

  group('mapWithdrawalFailure — تحويل الأكواد', () {
    test('يستخرج الكود المعروف من رسالة Postgres', () {
      const cases = {
        'AUTHORIZATION_DENIED: cannot approve a withdrawal of farm':
            'AUTHORIZATION_DENIED',
        'WITHDRAWAL_NOT_FOUND: ffffffff': 'WITHDRAWAL_NOT_FOUND',
        'INVALID_STATUS_TRANSITION: paid -> approved':
            'INVALID_STATUS_TRANSITION',
        'PARTNER_NOT_FOUND: ffffffff-0000': 'PARTNER_NOT_FOUND',
        'WITHDRAWAL_DISTRIBUTION_MISMATCH: farm mismatch':
            'WITHDRAWAL_DISTRIBUTION_MISMATCH',
        'NO_SESSION: approve_withdrawal requires an authenticated caller':
            'NO_SESSION',
      };

      for (final entry in cases.entries) {
        final failure = mapWithdrawalFailure(_FakePostgrestError(entry.key));
        expect(failure.code, entry.value, reason: entry.key);
        expect(failure.message, contains(entry.value));
      }
    });

    test('الكود المجهول يصير UNKNOWN', () {
      final failure = mapWithdrawalFailure(_FakePostgrestError('boom'));
      expect(failure.code, 'UNKNOWN');
      expect(failure.message, contains('boom'));
    });

    test('SyncFailure موجود يمرّ كما هو', () {
      final original = SyncFailure('WITHDRAWAL_CONFLICT', 'x');
      expect(mapWithdrawalFailure(original), same(original));
    });
  });

  group('PartnerSummary — النموذج', () {
    test('fromJson يقرأ الأعداد النصية ويعيد share_model افتراضي', () {
      final s = PartnerSummary.fromJson({
        'name': 'ن',
        'net_profit': '100',
        'pending': '25.5',
        'paid': '10',
      });
      expect(s.shareModel, 'percentage');
      expect(s.shareValue, isNull);
      expect(s.netProfit, 100);
      expect(s.available, 64.5);
    });
  });

  group('PartnerWithdrawalRepositoryImpl — النشر كما هو', () {
    test('ينشر SyncFailure من المصدر دون لفّه', () async {
      final repo = PartnerWithdrawalRepositoryImpl(remoteDatasource: ds);
      fake.onRpc = (_, __) =>
          throw _FakePostgrestError('AUTHORIZATION_DENIED: only manager');

      await expectLater(
        repo.approveWithdrawal(withdrawalId: 'w-1', approverId: 'a1'),
        throwsA(isA<SyncFailure>()
            .having((e) => e.code, 'code', 'AUTHORIZATION_DENIED')),
      );
    });

    test('getWithdrawals يمرّر الفلاتر كما هي', () async {
      fake.seed('partner_withdrawals', [withdrawalRow()]);
      final repo = PartnerWithdrawalRepositoryImpl(remoteDatasource: ds);

      final rows = await repo.getWithdrawals(partnerId: 'p1');
      expect(rows, hasLength(1));
      expect(fake.findCall('eq partner_id=p1'), isTrue);
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
