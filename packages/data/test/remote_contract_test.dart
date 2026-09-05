import 'dart:io';

import 'package:core/core.dart';
import 'package:data/src/datasources/remote/supabase_dispatch_datasource.dart';
import 'package:data/src/datasources/remote/supabase_egg_datasource.dart';
import 'package:data/src/datasources/remote/supabase_expense_datasource.dart';
import 'package:data/src/datasources/remote/supabase_farm_datasource.dart';
import 'package:data/src/datasources/remote/supabase_feed_datasource.dart';
import 'package:data/src/datasources/remote/supabase_flock_datasource.dart';
import 'package:data/src/datasources/remote/supabase_inventory_datasource.dart';
import 'package:data/src/datasources/remote/supabase_medication_datasource.dart';
import 'package:data/src/datasources/remote/supabase_mortality_datasource.dart';
import 'package:data/src/datasources/remote/supabase_notification_datasource.dart';
import 'package:data/src/datasources/remote/supabase_opening_balance_datasource.dart';
import 'package:data/src/datasources/remote/supabase_payment_datasource.dart';
import 'package:data/src/datasources/remote/supabase_storage_service.dart';
import 'package:data/src/datasources/remote/supabase_user_admin_datasource.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_supabase_api.dart';

void main() {
  late FakeSupabaseApi fake;

  setUp(() {
    fake = FakeSupabaseApi();
  });

  group('SupabaseEggDatasource — عقد إنتاج البيض', () {
    test('insert يرفع السجل ويعيد id من العمود الراجع', () async {
      final ds = SupabaseEggDatasource(fake);
      final id = await ds.insert(_egg());

      expect(id, startsWith('id-'));
      expect(fake.findCall('insert egg_production '), isTrue);
      expect(fake.tables['egg_production'], hasLength(1));
      expect(fake.tables['egg_production']!.first['cartons'], 5);
    });

    test('getRecords يطبّق مرشّحات farm/date والترتيب التنازلي', () async {
      fake.seed('egg_production', [
        {
          'id': 'r1',
          'farm_id': 'farm-1',
          'flock_id': 'flock-1',
          'date': '2026-08-01',
          'cartons': 1,
          'worker_id': 'worker-1',
        },
        {
          'id': 'r2',
          'farm_id': 'farm-2',
          'flock_id': 'flock-1',
          'date': '2026-09-01',
          'cartons': 2,
          'worker_id': 'worker-1',
        },
        {
          'id': 'r3',
          'farm_id': 'farm-1',
          'flock_id': 'flock-1',
          'date': '2026-08-10',
          'cartons': 3,
          'worker_id': 'worker-1',
        },
      ]);

      final ds = SupabaseEggDatasource(fake);
      final records = await ds.getRecords(
        farmId: 'farm-1',
        fromDate: DateTime(2026, 8, 1),
        toDate: DateTime(2026, 8, 31),
      );

      expect(records.map((r) => r.id).toList(), ['r3', 'r1']);
      expect(fake.findCall('eq farm_id=farm-1'), isTrue);
      expect(fake.findCall('gte date=2026-08-01'), isTrue);
      expect(fake.findCall('lte date=2026-08-31'), isTrue);
      expect(fake.findCall('date asc=false'), isTrue);
    });

    test('delete يمرّر الفلتر على id فقط', () async {
      await SupabaseEggDatasource(fake).delete('rec-9');
      expect(fake.findCall('delete egg_production eq id=rec-9'), isTrue);
    });
  });

  group('SupabaseMortalityDatasource — عقد النفوق', () {
    test('insert يعيد id والكيان يُخزَّن كاملاً', () async {
      final ds = SupabaseMortalityDatasource(fake);
      final id = await ds.insert(MortalityModel(
        farmId: 'farm-1',
        flockId: 'flock-1',
        date: DateTime(2026, 8, 20),
        count: 2,
        reason: MortalityReason.other,
        workerId: 'worker-1',
      ));

      expect(id, startsWith('id-'));
      expect(fake.findCall('insert mortality '), isTrue);
      expect(fake.tables['mortality']!.first['count'], 2);
    });

    test('uploadImage يعزل المسار تحت المزرعة ويرفع إلى bucket farm-images',
        () async {
      fake.storage; // ضمان إنشاء المخزن المزيّف
      final ds = SupabaseMortalityDatasource(fake);
      final url = await ds.uploadImage(
        File('test/support/dummy.jpg'),
        'rec-1',
        'farm-1',
      );

      expect(url, startsWith('https://fake.storage.example/farm-images/'));
      final path = fake.storageFiles['farm-images']!.keys.first;
      expect(path, startsWith('farms/farm-1/mortality/rec-1/'));
      expect(fake.findCall('storage upload farm-images '), isTrue);
      expect(fake.findCall('storage getPublicUrl farm-images '), isTrue);
    });

    test('delete يمرّر الفلتر على id', () async {
      await SupabaseMortalityDatasource(fake).delete('m-1');
      expect(fake.findCall('delete mortality eq id=m-1'), isTrue);
    });
  });

  group('SupabaseDispatchDatasource — عقد التخريج والزبائن', () {
    test('insert يرفع إلى egg_dispatch', () async {
      final ds = SupabaseDispatchDatasource(fake);
      final id = await ds.insert(DispatchModel(
        farmId: 'farm-1',
        date: DateTime(2026, 8, 20),
        customerId: 'cust-1',
        cartons: 10,
        trays: 2,
        workerId: 'worker-1',
      ));

      expect(id, startsWith('id-'));
      expect(fake.findCall('insert egg_dispatch '), isTrue);
      expect(fake.tables['egg_dispatch']!.first['cartons'], 10);
    });

    test('insertCustomer يمرّر upsert onConflict=id', () async {
      await SupabaseDispatchDatasource(fake)
          .insertCustomer('cust-7', CustomerModel(
        farmId: 'farm-1',
        name: 'زبون',
        phone: '0100',
      ));

      expect(fake.findCall('upsert customers '), isTrue);
      expect(fake.findCall('onConflict=id'), isTrue);
      expect(fake.tables['customers']!.first['id'], 'cust-7');
    });

    test('updateCustomer لا يرسل الأعمدة النظامية (id/version/...)', () async {
      fake.seed('customers', [
        {'id': 'cust-1', 'name': 'قديم', 'phone': '0'},
      ]);
      await SupabaseDispatchDatasource(fake).updateCustomer(CustomerModel(
        id: 'cust-1',
        farmId: 'farm-1',
        name: 'جديد',
        phone: '0111',
      ));

      final update = fake.calls.firstWhere((c) => c.startsWith('update customers '));
      expect(update.contains('"name":"جديد"'), isTrue);
      expect(update.contains('"phone":"0111"'), isTrue);
      expect(update.contains('"id"'), isFalse);
      expect(fake.tables['customers']!.first['name'], 'جديد');
    });

    test('getCustomers يفرز بالاسم', () async {
      fake.seed('customers', [
        {'id': 'c2', 'farm_id': 'farm-1', 'name': 'ب', 'phone': '2'},
        {'id': 'c1', 'farm_id': 'farm-1', 'name': 'أ', 'phone': '1'},
      ]);
      final customers = await SupabaseDispatchDatasource(fake)
          .getCustomers('farm-1');

      expect(customers.map((c) => c.id).toList(), ['c1', 'c2']);
      expect(fake.findCall('eq farm_id=farm-1'), isTrue);
      expect(fake.findCall('name asc=true'), isTrue);
    });
  });

  group('SupabaseFeedDatasource — عقد العلف', () {
    test('insertConsumption/insertReceived يرفعان إلى الجدولين الصحيحين',
        () async {
      final ds = SupabaseFeedDatasource(fake);
      await ds.insertConsumption(FeedConsumptionModel(
        farmId: 'farm-1',
        date: DateTime(2026, 8, 20),
        entryMode: FeedEntryMode.bags,
        bagsCount: 5,
        quantityKg: 150,
        workerId: 'worker-1',
      ));
      await ds.insertReceived(FeedReceivedModel(
        farmId: 'farm-1',
        date: DateTime(2026, 8, 20),
        entryMode: FeedEntryMode.kg,
        quantity: 10,
        quantityKg: 500,
        feedType: FeedType.main,
      ));

      expect(fake.findCall('insert feed_consumption '), isTrue);
      expect(fake.findCall('insert feed_received '), isTrue);
      expect(fake.tables['feed_received']!.first['feed_type'], 'main');
    });

    test('updateReceivedPrice يحدّث سعر الكيلو فقط', () async {
      fake.seed('feed_received', [
        {'id': 'f-1', 'price_per_kg': 20.0},
      ]);
      await SupabaseFeedDatasource(fake).updateReceivedPrice('f-1', 25.0);

      final update = fake.calls.firstWhere((c) => c.startsWith('update feed_received '));
      expect(update.contains('"price_per_kg":25.0'), isTrue);
      expect(update.contains('"quantity"'), isFalse);
    });

    test('deleteConsumption يمرّر id', () async {
      await SupabaseFeedDatasource(fake).deleteConsumption('fc-1');
      expect(fake.findCall('delete feed_consumption eq id=fc-1'), isTrue);
    });
  });

  group('SupabasePaymentDatasource — عقد المدفوعات', () {
    test('insert يعيد الصف الكامل عبر RETURNING', () async {
      final row = await SupabasePaymentDatasource(fake).insert(PaymentModel(
        farmId: 'farm-1',
        customerId: 'cust-1',
        date: DateTime(2026, 8, 20),
        pricePerCarton: 45.0,
        totalDue: 900.0,
        amountPaid: 900.0,
        paymentMethod: PaymentMethod.cash,
        managerId: 'manager-1',
      ));

      expect(row['id'], startsWith('id-'));
      expect(fake.findCall('insert payments '), isTrue);
    });

    test('update لا يرسل id', () async {
      fake.seed('payments', [
        {'id': 'p-1', 'total_due': 1.0},
      ]);
      await SupabasePaymentDatasource(fake).update('p-1', PaymentModel(
        farmId: 'farm-1',
        customerId: 'cust-1',
        date: DateTime(2026, 8, 20),
        pricePerCarton: 45.0,
        totalDue: 800.0,
        amountPaid: 400.0,
        paymentMethod: PaymentMethod.transfer,
        managerId: 'manager-1',
      ));

      final update = fake.calls.firstWhere((c) => c.startsWith('update payments '));
      expect(update.contains('"id"'), isFalse);
      expect(update.contains('"total_due":800.0'), isTrue);
    });

    test('getPayments يطبّق نطاق التاريخ', () async {
      await SupabasePaymentDatasource(fake).getPayments(
        farmId: 'farm-1',
        fromDate: DateTime(2026, 8, 1),
        toDate: DateTime(2026, 8, 31),
      );
      expect(fake.findCall('eq farm_id=farm-1'), isTrue);
      expect(fake.findCall('gte date=2026-08-01'), isTrue);
      expect(fake.findCall('lte date=2026-08-31'), isTrue);
    });
  });

  group('SupabaseExpenseDatasource — عقد المصروفات', () {
    test('insert عبر RETURNING وإزالته بالفلتر', () async {
      final ds = SupabaseExpenseDatasource(fake);
      final row = await ds.insert(ExpenseModel(
        farmId: 'farm-1',
        date: DateTime(2026, 8, 20),
        category: ExpenseCategory.feed,
        amount: 1500,
      ));

      expect(row['id'], startsWith('id-'));
      expect(fake.tables['expenses'], hasLength(1));

      await ds.delete(row['id'] as String);
      expect(fake.findCall('delete expenses eq id='), isTrue);
      expect(fake.tables['expenses'], isEmpty);
    });
  });

  group('SupabaseInventoryDatasource — عقد المخزون', () {
    test('insertTransaction يكتب الحركة ويحدّث الكمية', () async {
      final ds = SupabaseInventoryDatasource(fake);
      await ds.insertTransaction(
        InventoryTransactionModel(
          itemId: 'item-1',
          date: DateTime(2026, 8, 20),
          isInput: true,
          quantity: 5,
        ),
        newQuantity: 15,
      );

      expect(fake.findCall('insert inventory_transactions '), isTrue);
      final update = fake.calls.firstWhere((c) => c.startsWith('update inventory_items '));
      expect(update.contains('eq id=item-1'), isTrue);
    });

    test('getItems يفرز بالاسم ويفلتر المزرعة', () async {
      fake.seed('inventory_items', [
        {'id': 'i2', 'farm_id': 'farm-1', 'name': 'علف'},
        {'id': 'i1', 'farm_id': 'farm-1', 'name': 'دواء'},
      ]);
      final items = await SupabaseInventoryDatasource(fake).getItems('farm-1');
      expect(items.map((e) => e.id).toList(), ['i1', 'i2']);
      expect(fake.findCall('name asc=true'), isTrue);
    });
  });

  group('SupabaseFlockDatasource — عقد القطعان', () {
    test('endFlock يرسل status=depleted فقط', () async {
      final update = SupabaseFlockDatasource(fake);
      await update.endFlock('flock-1');

      final call = fake.calls.firstWhere((c) => c.startsWith('update flocks '));
      expect(call.contains('"status":"depleted"'), isTrue);
      expect(call.contains('eq id=flock-1'), isTrue);
    });

    test('getFlocks يفلتر المزرعة', () async {
      await SupabaseFlockDatasource(fake).getFlocks('farm-1');
      expect(fake.findCall('eq farm_id=farm-1'), isTrue);
    });
  });

  group('SupabaseFarmDatasource — عقد المدجنة', () {
    test('getFarm يقرأ عبر maybeSingle', () async {
      fake.seed('farms', [
        {'id': 'farm-1', 'name': 'مزرعة'},
      ]);
      final farm = await SupabaseFarmDatasource(fake).getFarm('farm-1');
      expect(farm.id, 'farm-1');
      expect(fake.findCall('eq id=farm-1'), isTrue);
    });
  });

  group('SupabaseOpeningBalanceDatasource — عقد الأرصدة الافتتاحية', () {
    test('getForFlock يجمع مرشّحين ويحدّ النتيجة', () async {
      fake.seed('opening_balances', [
        {
          'id': 'b1',
          'farm_id': 'farm-1',
          'flock_id': 'flock-1',
          'created_at': '2026-08-20T10:00:00.000',
        },
      ]);
      final ds = SupabaseOpeningBalanceDatasource(fake);
      final b = await ds.getForFlock('farm-1', 'flock-1');
      expect(b, isNotNull);
      expect(fake.findCall('eq farm_id=farm-1'), isTrue);
      expect(fake.findCall('eq flock_id=flock-1'), isTrue);
      expect(fake.findCall('opening_balances 1'), isTrue);
    });

    test('upsert والـ delete بمرشّحين', () async {
      final ds = SupabaseOpeningBalanceDatasource(fake);
      await ds.delete('farm-1', 'flock-1');
      expect(
          fake.findCall('delete opening_balances eq farm_id=farm-1 eq flock_id=flock-1'),
          isTrue);
    });
  });

  group('SupabaseNotificationDatasource — عقد الإشعارات', () {
    test('getActiveNotifications يضيف فلتر is_active', () async {
      fake.seed('app_notifications', [
        {
          'id': 'n1',
          'farm_id': 'farm-1',
          'title': 'تنبيه',
          'date': '2026-08-20',
          'is_active': true,
        },
        {
          'id': 'n2',
          'farm_id': 'farm-1',
          'title': 'تنبيه',
          'date': '2026-08-21',
          'is_active': false,
        },
      ]);
      final rows =
          await SupabaseNotificationDatasource(fake).getActiveNotifications('farm-1');
      expect(rows, hasLength(1));
      expect(fake.findCall('eq is_active=true'), isTrue);
      expect(fake.findCall('created_at asc=false'), isTrue);
    });

    test('toggleActive يحدّث is_active فقط', () async {
      await SupabaseNotificationDatasource(fake).toggleActive('n1', false);
      final call = fake.calls.firstWhere((c) => c.startsWith('update app_notifications '));
      expect(call.contains('"is_active":false'), isTrue);
    });
  });

  group('SupabaseMedicationDatasource — عقد الأدوية', () {
    test('insert إلى medications وقراءة الكتالوج', () async {
      final ds = SupabaseMedicationDatasource(fake);
      await ds.insert(MedicationModel(
        farmId: 'farm-1',
        date: DateTime(2026, 8, 20),
        type: MedicationType.drug,
        medicineName: 'أموكسي',
        dosage: '1/1000',
        administrationRoute: AdministrationRoute.water,
        workerId: 'worker-1',
      ));
      expect(fake.findCall('insert medications '), isTrue);

      await ds.getMedicinesCatalog();
      expect(fake.findCall('select medicines_catalog '), isTrue);
      expect(fake.findCall('name asc=true'), isTrue);
    });
  });

  group('SupabaseUserAdminDatasource — عقود admin RPC', () {
    test('getAllUsers يستدعي admin_select_all_users', () async {
      fake.onRpc = (name, _) => [
            {
              'id': 'u1',
              'name': 'م',
              'phone': '0',
              'role': 'worker',
              'farm_id': 'f',
              'is_active': true,
              'created_at': null,
            },
          ];

      final users = await SupabaseUserAdminDatasource(fake).getAllUsers();
      expect(users, hasLength(1));
      expect(fake.findCall('rpc admin_select_all_users '), isTrue);
    });

    test('createUser يمرّر كامل المعاملات بالاسم المرمّز', () async {
      fake.onRpc = (_, __) => {
            'id': 'u1',
            'name': 'م',
            'phone': '0100',
            'role': 'worker',
            'farm_id': 'farm-1',
            'is_active': true,
            'created_at': null,
          };
      final ds = SupabaseUserAdminDatasource(fake);
      await ds.createUser(
        farmId: 'farm-1',
        name: 'م',
        phone: '0100',
        pin: '1234',
        role: UserRole.worker,
      );

      final call = fake.calls.last;
      expect(call.startsWith('rpc admin_create_user '), isTrue);
      expect(call.contains('"p_farm_id":"farm-1"'), isTrue);
      expect(call.contains('"p_role":"worker"'), isTrue);
      expect(call.contains('"p_pin":"1234"'), isTrue);
    });

    test('updateUser يمرّر الحقول الفارغة كقيم null صريحة', () async {
      await SupabaseUserAdminDatasource(fake).updateUser(
        uid: 'u1',
        isActive: false,
      );
      final call = fake.calls.last;
      expect(call.contains('"p_uid":"u1"'), isTrue);
      expect(call.contains('"p_is_active":false'), isTrue);
      expect(call.contains('"p_name":null'), isTrue);
    });

    test('resetPin/deleteUser بأسماء الدوال الصحيحة', () async {
      final ds = SupabaseUserAdminDatasource(fake);
      await ds.resetPin(uid: 'u1', newPin: '7777');
      expect(fake.findCall('rpc admin_reset_pin '), isTrue);

      await ds.deleteUser('u1');
      expect(fake.findCall('rpc admin_delete_user '), isTrue);
    });
  });

  group('SupabaseStorageService — عقد رفع الملفات', () {
    test('uploadImage يرفع ويعيد رابطاً عاماً، وdeleteImage يزيل', () async {
      final svc = SupabaseStorageService(fake.storage);
      final url = await svc.uploadImage(
        bucket: 'farm-images',
        path: 'farms/farm-1/mortality/m-1/a.jpg',
        file: File('test/support/dummy.jpg'),
      );
      expect(url, 'https://fake.storage.example/farm-images/farms/farm-1/mortality/m-1/a.jpg');
      expect(fake.findCall('storage upload farm-images '), isTrue);

      await svc.deleteImage(bucket: 'farm-images', path: 'a.jpg');
      expect(fake.findCall('storage remove farm-images '), isTrue);
    });

    test('فشل الرفع يتحوّل إلى StorageException', () async {
      fake.failStorage = true;
      final svc = SupabaseStorageService(fake.storage);
      expect(
        () => svc.uploadImage(
          bucket: 'farm-images',
          path: 'x.jpg',
          file: File('test/support/dummy.jpg'),
        ),
        throwsA(isA<StorageException>()),
      );
    });
  });

  group('عقود مشتركة قارئة (select/order/limit)', () {
    test('يبني استعلام select صريحاً قبل الجلب', () async {
      fake.seed('medicines_catalog', [
        {'id': 'm1', 'name': 'دواء'},
      ]);
      await SupabaseMedicationDatasource(fake).getMedicinesCatalog();

      expect(fake.findCall('select medicines_catalog '), isTrue);
    });
  });
}

EggProductionModel _egg() => EggProductionModel(
      farmId: 'farm-1',
      flockId: 'flock-1',
      date: DateTime(2026, 8, 20),
      cartons: 5,
      trays: 1,
      looseEggs: 10,
      workerId: 'worker-1',
    );