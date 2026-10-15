import 'package:core/core.dart';
import 'package:data/src/datasources/remote/supabase_partner_datasource.dart';
import 'package:data/src/repositories/partner_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_supabase_api.dart';

void main() {
  late FakeSupabaseApi fake;
  late SupabasePartnerDatasource ds;

  setUp(() {
    fake = FakeSupabaseApi();
    ds = SupabasePartnerDatasource(fake);
  });

  group('SupabasePartnerDatasource — عقد الشركاء', () {
    test('fetch يفرز بالاسم ويستبعد المحذوفين افتراضياً', () async {
      fake.seed('partners', [
        {
          'id': 'p2',
          'name': 'ب',
          'status': 'active',
          'share_model': 'percentage',
          'percentage': 10,
          'currency': 'dollar',
        },
        {
          'id': 'p1',
          'name': 'أ',
          'status': 'active',
          'share_model': 'salary',
          'salary_amount': 100,
          'salary_period': 'monthly',
          'currency': 'dollar',
        },
        {
          'id': 'p3',
          'name': 'ج',
          'status': 'inactive',
          'deleted_at': '2026-09-01T00:00:00Z',
          'share_model': 'percentage',
          'percentage': 5,
          'currency': 'dollar',
        },
      ]);

      final partners = await ds.fetch();

      expect(partners.map((p) => p.id).toList(), ['p1', 'p2']);
      expect(fake.findCall('select partners '), isTrue);
      expect(fake.findCall('name asc=true'), isTrue);
    });

    test('fetch(includeDeleted: true) يعيد المحذوفين أيضاً', () async {
      fake.seed('partners', [
        {'id': 'p1', 'name': 'أ', 'deleted_at': '2026-09-01T00:00:00Z'},
      ]);

      final partners = await ds.fetch(includeDeleted: true);

      expect(partners, hasLength(1));
      expect(partners.single.isDeleted, isTrue);
    });

    test('insert يزيل id ويرسل أعمدة الكتابة فقط', () async {
      await ds.insert(PartnerModel(
        id: 'should-be-removed',
        name: 'شريك',
        shareModel: ShareModel.salary,
        salaryAmount: 500,
        salaryPeriod: SalaryPeriod.monthly,
      ));

      final call = fake.calls.firstWhere((c) => c.startsWith('insert partners '));
      expect(call.contains('"id"'), isFalse);
      expect(call.contains('"name":"شريك"'), isTrue);
      expect(call.contains('"share_model":"salary"'), isTrue);
      expect(call.contains('"salary_period":"monthly"'), isTrue);
      expect(call.contains('"currency":"dollar"'), isTrue);
    });

    test('update يفلتر على id ولا يرسل id', () async {
      fake.seed('partners', [
        {'id': 'p1', 'name': 'قديم'},
      ]);

      await ds.update(PartnerModel(
        id: 'p1',
        name: 'جديد',
        shareModel: ShareModel.percentage,
        percentage: 25,
      ));

      final call = fake.calls.firstWhere((c) => c.startsWith('update partners '));
      expect(call.contains('eq id=p1'), isTrue);
      expect(call.contains('"id"'), isFalse);
      expect(call.contains('"name":"جديد"'), isTrue);
      expect(fake.tables['partners']!.first['name'], 'جديد');
    });

    test('softDelete/restore يضبطان deleted_at على id', () async {
      fake.seed('partners', [
        {'id': 'p1', 'name': 'شريك', 'deleted_at': null},
      ]);

      await ds.softDelete('p1');
      expect(fake.tables['partners']!.first['deleted_at'], isNotNull);

      await ds.restore('p1');
      expect(fake.tables['partners']!.first['deleted_at'], isNull);
      expect(fake.findCall('eq id=p1'), isTrue);
    });
  });

  group('PartnerModel — التحقق من نموذج الحصة', () {
    test('يقبل ويرفض وفق قيد partners_share_model_fields', () {
      expect(
        PartnerModel(
                name: 'x',
                shareModel: ShareModel.percentage,
                percentage: 50)
            .hasValidShareFields,
        isTrue,
      );
      expect(
        PartnerModel(name: 'x', shareModel: ShareModel.percentage)
            .hasValidShareFields,
        isFalse,
      );
      expect(
        PartnerModel(name: 'x', shareModel: ShareModel.percentage, percentage: 120)
            .hasValidShareFields,
        isFalse,
      );
      expect(
        PartnerModel(name: 'x', shareModel: ShareModel.shares, shares: 0)
            .hasValidShareFields,
        isTrue,
      );
      expect(
        PartnerModel(
          name: 'x',
          shareModel: ShareModel.salary,
          salaryAmount: 500,
          salaryPeriod: SalaryPeriod.monthly,
        ).hasValidShareFields,
        isTrue,
      );
      expect(
        PartnerModel(name: 'x', shareModel: ShareModel.salary, salaryAmount: 500)
            .hasValidShareFields,
        isFalse,
      );
      expect(
        PartnerModel(
          name: 'x',
          shareModel: ShareModel.mixed,
          salaryAmount: 500,
          salaryPeriod: SalaryPeriod.perCycle,
          percentage: 20,
        ).hasValidShareFields,
        isTrue,
      );
      expect(
        PartnerModel(
          name: 'x',
          shareModel: ShareModel.mixed,
          salaryAmount: 500,
          salaryPeriod: SalaryPeriod.monthly,
        ).hasValidShareFields,
        isFalse,
      );
    });

    test('fromJson يقرأ الحقول ويحوّل التعدادات', () {
      final p = PartnerModel.fromJson({
        'id': 'p1',
        'user_id': 'u1',
        'name': 'شريك',
        'status': 'suspended',
        'partner_role': 'investor',
        'share_model': 'mixed',
        'percentage': 30,
        'shares': null,
        'salary_amount': 1000,
        'salary_period': 'per_cycle',
        'currency': 'lira',
        'effective_from': '2026-01-01',
        'effective_to': null,
        'created_at': '2026-01-01T00:00:00Z',
        'deleted_at': null,
      });

      expect(p.status, PartnerStatus.suspended);
      expect(p.partnerRole, PartnerRole.investor);
      expect(p.shareModel, ShareModel.mixed);
      expect(p.salaryPeriod, SalaryPeriod.perCycle);
      expect(p.currency, AppCurrency.lira);
      expect(p.percentage, 30);
      expect(p.isDeleted, isFalse);
      expect(p.hasValidShareFields, isTrue);
    });

    test('fromJson يعيد القيم الافتراضية عند غياب الحقول', () {
      final p = PartnerModel.fromJson({'id': 'p1'});
      expect(p.name, '');
      expect(p.status, PartnerStatus.active);
      expect(p.shareModel, ShareModel.percentage);
      expect(p.currency, AppCurrency.dollar);
    });
  });

  group('PartnerRepositoryImpl — ترجمة الأخطاء', () {
    test('يغلّف خطأ القراءة برسالة الاستثناء الحقيقية', () async {
      fake.failReads = true;
      final repo = PartnerRepositoryImpl(remoteDatasource: ds);

      await expectLater(
        repo.getPartners(),
        throwsA(predicate((e) => e.toString().contains('fake read failure'))),
      );
    });
  });
}
