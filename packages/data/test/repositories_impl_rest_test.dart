import 'dart:io';

import 'package:core/core.dart';
import 'package:data/src/datasources/local/daos/expense_dao.dart';
import 'package:data/src/datasources/local/daos/feed_dao.dart';
import 'package:data/src/datasources/local/daos/flock_dao.dart';
import 'package:data/src/datasources/local/daos/inventory_dao.dart';
import 'package:data/src/datasources/local/daos/medication_dao.dart';
import 'package:data/src/datasources/local/daos/mortality_dao.dart';
import 'package:data/src/datasources/local/daos/opening_balance_dao.dart';
import 'package:data/src/datasources/local/daos/settings_dao.dart';
import 'package:data/src/datasources/local/daos/user_dao.dart';
import 'package:data/src/datasources/local/local_database.dart';
import 'package:data/src/datasources/remote/supabase_dispatch_datasource.dart';
import 'package:data/src/datasources/remote/supabase_expense_datasource.dart';
import 'package:data/src/datasources/remote/supabase_farm_datasource.dart';
import 'package:data/src/datasources/remote/supabase_feed_datasource.dart';
import 'package:data/src/datasources/remote/supabase_inventory_datasource.dart';
import 'package:data/src/datasources/remote/supabase_medication_datasource.dart';
import 'package:data/src/datasources/remote/supabase_mortality_datasource.dart';
import 'package:data/src/datasources/remote/supabase_notification_datasource.dart';
import 'package:data/src/datasources/remote/supabase_opening_balance_datasource.dart';
import 'package:data/src/datasources/remote/supabase_user_admin_datasource.dart';
import 'package:data/src/repositories/dispatch_repository_impl.dart';
import 'package:data/src/repositories/expense_repository_impl.dart';
import 'package:data/src/repositories/farm_repository_impl.dart';
import 'package:data/src/repositories/feed_repository_impl.dart';
import 'package:data/src/repositories/inventory_repository_impl.dart';
import 'package:data/src/repositories/medication_repository_impl.dart';
import 'package:data/src/repositories/mortality_repository_impl.dart';
import 'package:data/src/repositories/notification_repository_impl.dart';
import 'package:data/src/repositories/opening_balance_repository_impl.dart';
import 'package:data/src/repositories/user_admin_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/db_harness.dart';
import 'support/fake_supabase_api.dart';

void main() {
  setUpAll(enableFfiDatabase);

  late Directory dbDir;
  late FakeSupabaseApi fake;

  setUp(() async {
    dbDir = await createDbHarness('repos_rest');
    fake = FakeSupabaseApi();
  });

  tearDown(() => tearDownDbHarness(dbDir));

  group('MortalityRepositoryImpl - النفوق', () {
    MortalityRepositoryImpl repo() => MortalityRepositoryImpl(
          localDao: MortalityDao(),
          remoteDatasource: SupabaseMortalityDatasource(fake),
        );

    MortalityModel record() => MortalityModel(
          farmId: 'farm-1',
          flockId: 'flock-1',
          date: DateTime(2026, 8, 20),
          count: 5,
          reason: MortalityReason.cannibalism,
          workerId: 'w1',
        );

    test('saveLocal يحفظ محلياً pending دون ملامسة السحابة', () async {
      final dao = MortalityDao();
      await repo().saveLocal(record());

      expect(await dao.countPending(), 1);
      expect(fake.tables['mortality'] ?? [], isEmpty);
      final all = await dao.getAll(farmId: 'farm-1');
      expect(all.single.syncStatus, SyncStatus.pending);
    });

    test('syncPendingRecords يرفع ويعيّن synced', () async {
      final dao = MortalityDao();
      final r = repo();
      await r.saveLocal(record());
      await r.syncPendingRecords();

      expect(await dao.countPending(), 0);
      expect((await dao.getAll(farmId: 'farm-1')).single.syncStatus,
          SyncStatus.synced);
      expect(fake.tables['mortality'], hasLength(1));
    });

    test('uploadImage يرفع للـ Storage ويعيد رابطاً عاماً، والفشل يُرجع null',
        () async {
      final repo = repo();
      final f = File('${Directory.systemTemp.path}/mortality_test.jpg');
      await f.writeAsBytes([1, 2, 3]);

      final url = await repo.uploadImage(f, 'rec-1', 'farm-1');
      expect(url, startsWith('https://fake.storage.example/farm-images/'));
      expect(fake.findCall('storage upload farm-images'), isTrue);
      expect(fake.storageFiles['farm-images'], isNotEmpty);

      fake.failStorage = true;
      expect(await repo.uploadImage(f, 'rec-2', 'farm-1'), isNull);
      await f.delete();
    });
  });

  group('FeedRepositoryImpl - العلف', () {
    FeedRepositoryImpl repo() => FeedRepositoryImpl(
          localDao: FeedDao(),
          remoteDatasource: SupabaseFeedDatasource(fake),
        );

    FeedConsumptionModel consumption({double kg = 100}) =>
        FeedConsumptionModel(
          farmId: 'farm-1',
          date: DateTime(2026, 8, 20),
          entryMode: FeedEntryMode.kg,
          quantityKg: kg,
          workerId: 'w1',
        );

    FeedReceivedModel received({double kg = 500}) => FeedReceivedModel(
          farmId: 'farm-1',
          date: DateTime(2026, 8, 20),
          entryMode: FeedEntryMode.kg,
          quantity: kg,
          quantityKg: kg,
          feedType: FeedType.main,
          supplier: 'مطحنة الشرق',
        );

    test('getCurrentFeedStock = اجمالي الوارد - اجمالي المستهلك', () async {
      final dao = FeedDao();
      final r = repo();
      await r.saveReceivedLocal(received(kg: 500));
      await r.saveReceivedLocal(received(kg: 250));
      await r.saveConsumptionLocal(consumption(kg: 100));
      await r.saveConsumptionLocal(consumption(kg: 50));

      expect(await r.getCurrentFeedStock('farm-1'), 600);
      expect(await dao.getTodayConsumption('farm-1'), hasLength(2));
    });

    test('syncPendingConsumption يرفع المستهلك والوارد معاً', () async {
      final dao = FeedDao();
      final r = repo();
      await r.saveReceivedLocal(received());
      await r.saveConsumptionLocal(consumption());

      await r.syncPendingConsumption();

      expect(await dao.getPendingConsumption(), isEmpty);
      expect(await dao.getPendingReceived(), isEmpty);
      expect(fake.tables['feed_consumption'], hasLength(1));
      expect(fake.tables['feed_received'], hasLength(1));
    });

    test('setReceivedPrice يحدّث محلياً والبعيد', () async {
      final dao = FeedDao();
      final id = await dao.insertReceived(received().toJson());
      await repo().setReceivedPrice(id: id, pricePerKg: 12.5);

      expect(fake.findCall('price'), isTrue);
      final updated = await dao.getAllReceived(farmId: 'farm-1');
      expect(updated.single.pricePerKg, 12.5);
    });

    test('deleteConsumptionRecord يحذف محلياً', () async {
      final dao = FeedDao();
      final id = await dao.insertConsumption(consumption());
      await repo().deleteConsumptionRecord(id);
      expect(await dao.getAllConsumption(farmId: 'farm-1'), isEmpty);
    });
  });

  group('ExpenseRepositoryImpl - المصروفات', () {
    ExpenseRepositoryImpl repo() => ExpenseRepositoryImpl(
          localDao: ExpenseDao(),
          remoteDatasource: SupabaseExpenseDatasource(fake),
        );

    ExpenseModel expense() => ExpenseModel(
          farmId: 'farm-1',
          date: DateTime(2026, 8, 20),
          category: ExpenseCategory.electricity,
          amount: 1500,
          description: 'فاتورة الكهرباء',
        );

    test('save (جديد) يحفظ محلياً ويرفع للبعيد ويجعل الحالة synced', () async {
      final dao = ExpenseDao();
      final r = repo();
      await r.save(expense());

      expect(await dao.countPending(), 0);
      final all = await dao.getAll(farmId: 'farm-1');
      expect(all.single.syncStatus, SyncStatus.synced);
      expect(fake.tables['expenses'], hasLength(1));
    });

    test('save عند انقطاع الشبكة يبقى pending محلياً', () async {
      final dao = ExpenseDao();
      fake.failWrites = true;
      await repo().save(expense());

      expect(await dao.countPending(), 1);
      expect(await dao.getPendingModels(), hasLength(1));
    });

    test('syncPendingRecords يرفع المصروفات المعلقة', () async {
      final dao = ExpenseDao();
      fake.failWrites = true;
      await repo().save(expense());
      fake.failWrites = false;

      await repo().syncPendingRecords();

      expect(await dao.countPending(), 0);
      expect(await dao.getAll(farmId: 'farm-1'), hasLength(1));
    });

    test('getExpenses: عبر الإنترنت يكشّ قيمة محلياً، وعند الانقطاع من المحلي',
        () async {
      final r = repo();
      fake.seed('expenses', [
        {
          'id': 'exp-1',
          'farm_id': 'farm-1',
          'date': '2026-08-19',
          'category': 'feed',
          'amount': 800,
        },
      ]);

      final online = await r.getExpenses(farmId: 'farm-1');
      expect(online.single.amount, 800);
      // الكاش المحلي حُدّث
      expect((await ExpenseDao().getAll(farmId: 'farm-1')), hasLength(1));

      fake.failReads = true;
      final offline = await r.getExpenses(farmId: 'farm-1');
      expect(offline.single.amount, 800);
    });

    test('getTotal يجمع المصروفات', () async {
      final r = repo();
      fake.seed('expenses', [
        {
          'id': 'x1',
          'farm_id': 'farm-1',
          'date': '2026-08-01',
          'category': 'water',
          'amount': 100,
        },
        {
          'id': 'x2',
          'farm_id': 'farm-1',
          'date': '2026-08-02',
          'category': 'labor',
          'amount': 250,
        },
      ]);
      expect(await r.getTotal(farmId: 'farm-1'), 350);
    });
  });

  group('MedicationRepositoryImpl - الأدوية', () {
    MedicationRepositoryImpl repo() => MedicationRepositoryImpl(
          localDao: MedicationDao(),
          remoteDatasource: SupabaseMedicationDatasource(fake),
        );

    test('كاش فارغ + سحابة متاحة: يجلب ويُسرّب الكاش المحلي', () async {
      fake.seed('medicines_catalog', [
        {'id': 'm1', 'name': 'فيتامين', 'type': 'vitamin', 'withdrawal_days': 0},
      ]);
      final dao = MedicationDao();
      final catalog = await repo().getMedicinesCatalog();

      expect(catalog.single.name, 'فيتامين');
      expect(await dao.getCatalog(), hasLength(1));
    });

    test('كاش محلي موجود: لا يلمس السحابة', () async {
      final dao = MedicationDao();
      await dao.seedCatalog(const [
        MedicineModel(
            id: 'm1', name: 'محلي', type: MedicationType.drug, withdrawalDays: 7),
      ]);
      final catalog = await repo().getMedicinesCatalog();
      expect(catalog.single.name, 'محلي');
      expect(fake.calls, isEmpty);
    });

    test('كاش فارغ + سحابة فارغة: يعود للقائمة الافتراضية', () async {
      final catalog = await repo().getMedicinesCatalog();
      expect(catalog, hasLength(5));
      expect(catalog.first.name, 'فيتامين A+D3+E');
    });

    test('saveMedicine / deleteMedicine يعملان محلياً فوراً', () async {
      final dao = MedicationDao();
      await repo().saveMedicine(const MedicineModel(
          id: 'm9', name: 'مطهر', type: MedicationType.drug, withdrawalDays: 0));
      expect(await dao.getCatalog(), hasLength(1));

      await repo().deleteMedicine('m9');
      expect(await dao.getCatalog(), isEmpty);
    });

    test('syncPendingRecords يعيّن synced', () async {
      final dao = MedicationDao();
      final r = repo();
      await r.saveLocal(MedicationModel(
        farmId: 'farm-1',
        flockId: 'flock-1',
        date: DateTime(2026, 8, 20),
        type: MedicationType.drug,
        medicineName: 'مضاد حيوي',
        dosage: '1جم/لتر',
        administrationRoute: AdministrationRoute.water,
        workerId: 'w1',
      ));
      expect(await r.getPendingCount(), 1);

      await r.syncPendingRecords();
      expect(await r.getPendingCount(), 0);
      final record = (await dao.getAll(farmId: 'farm-1')).single;
      expect(record.syncStatus, SyncStatus.synced);
    });
  });

  group('InventoryRepositoryImpl - المخزون', () {
    InventoryRepositoryImpl repo() => InventoryRepositoryImpl(
          localDao: InventoryDao(),
          remoteDatasource: SupabaseInventoryDatasource(fake),
        );

    test('getItems عبر الإنترنت يحدّث الكاش، وعند الانقطاع يعيد المحلي',
        () async {
      final r = repo();
      fake.seed('inventory_items', [
        {
          'id': 'it-1',
          'farm_id': 'farm-1',
          'name': 'خيط',
          'unit': 'kg',
          'quantity': 10,
          'low_stock_threshold': 2,
        },
      ]);

      final online = await r.getItems('farm-1');
      expect(online.single.name, 'خيط');
      expect((await InventoryDao().getItems('farm-1')), hasLength(1));

      fake.failReads = true;
      expect(await r.getItems('farm-1'), hasLength(1));
    });

    test('saveItem بلا id: يحفظ محلياً ثم يعيد كتابة عنصر البعيد', () async {
      final dao = InventoryDao();
      await repo().saveItem(InventoryItemModel(
        farmId: 'farm-1',
        name: 'دواء بيطري',
        unit: InventoryUnit.piece,
        quantity: 4,
        lowStockThreshold: 1,
      ));

      expect(await dao.getItems('farm-1'), hasLength(1));
      expect(fake.tables['inventory_items'], hasLength(1));
    });

    test('adjustStock: إدخال وإخراج، ورفض الإخراج الأكبر من المتوفر', () async {
      final r = repo();
      await r.saveItem(InventoryItemModel(
        id: 'it-1',
        farmId: 'farm-1',
        name: 'بيض',
        unit: InventoryUnit.piece,
        quantity: 50,
        lowStockThreshold: 5,
      ));

      final afterInput = await r.adjustStock(
          itemId: 'it-1', isInput: true, quantity: 100);
      expect(afterInput.quantity, 150);

      final afterOutput = await r.adjustStock(
          itemId: 'it-1', isInput: false, quantity: 30, note: 'استهلاك');
      expect(afterOutput.quantity, 120);
      expect(
        () => r.adjustStock(itemId: 'it-1', isInput: false, quantity: 500),
        throwsA(predicate((e) => '$e'.contains('أكبر من المتوفر'))),
      );
      expect(
        () => r.adjustStock(itemId: 'missing', isInput: true, quantity: 1),
        throwsA(predicate((e) => '$e'.contains('غير موجود'))),
      );
    });
  });

  group('OpeningBalanceRepositoryImpl - الأرصدة الافتتاحية', () {
    OpeningBalanceRepositoryImpl repo() => OpeningBalanceRepositoryImpl(
          localDao: OpeningBalanceDao(),
          remoteDatasource: SupabaseOpeningBalanceDatasource(fake),
        );

    Map<String, dynamic> remoteRow(String id) => {
          'id': id,
          'farm_id': 'farm-1',
          'flock_id': 'flock-$id',
          'created_at': '2026-07-01T00:00:00.000',
          'initial_birds': 2000,
          'eggs_produced': 150,
          'total_revenues': 30000,
        };

    test('getForFlock: البعيد أولاً مع تحديث الكاش المحلي', () async {
      fake.seed('opening_balances', [remoteRow('1')]);
      final r = repo();

      final balance = await r.getForFlock('farm-1', 'flock-1');
      expect(balance!.initialBirds, 2000);
      expect((await OpeningBalanceDao().getForFlock('farm-1', 'flock-1')),
          isNotNull);
    });

    test('getForFlock عند الانقطاع: من المحلي', () async {
      final dao = OpeningBalanceDao();
      await dao.save(OpeningBalanceModel(
        id: 'loc-1',
        farmId: 'farm-1',
        flockId: 'flock-loc',
        createdAt: DateTime(2026, 7, 1),
        initialBirds: 100,
      ));
      fake.failReads = true;

      final balance = await repo().getForFlock('farm-1', 'flock-loc');
      expect(balance!.initialBirds, 100);
    });

    test('save يحفظ محلياً ويرفع upsert للبعيد', () async {
      final r = repo();
      await r.save(OpeningBalanceModel(
        id: 'ob-1',
        farmId: 'farm-1',
        flockId: 'flock-1',
        createdAt: DateTime(2026, 7, 1),
      ));
      expect((await OpeningBalanceDao().getForFlock('farm-1', 'flock-1')),
          isNotNull);
      expect(fake.tables['opening_balances'], hasLength(1));
    });

    test('delete يمسح محلياً من دون خطأ عند انقطاع الشبكة', () async {
      final dao = OpeningBalanceDao();
      await dao.save(OpeningBalanceModel(
        id: 'ob-x',
        farmId: 'farm-1',
        flockId: 'flock-x',
        createdAt: DateTime(2026, 7, 1),
      ));
      fake.failWrites = true;
      await repo().delete('farm-1', 'flock-x');
      expect(await dao.getForFlock('farm-1', 'flock-x'), isNull);
    });
  });

  group('DispatchRepositoryImpl - التخريج والزبائن', () {
    DispatchRepositoryImpl repo() => DispatchRepositoryImpl(
          localDao: DispatchDao(),
          customerDao: CustomerDao(),
          remoteDatasource: SupabaseDispatchDatasource(fake),
        );

    test('addCustomer: حفظ محلي ثم رفع للبعيد ووضع synced', () async {
      final id = await repo().addCustomer(CustomerModel(
        farmId: 'farm-1',
        name: 'محمود',
        phone: '0933',
      ));

      final db = await LocalDatabase.database;
      final row = (await db.query('customers',
              where: 'id = ?', whereArgs: [id] as List))
          .single;
      expect(row['sync_status'], SyncStatus.synced.name);
    });

    test('syncCustomersFromRemote يزرع زبائن السحابة في الكاش المحلي', () async {
      fake.seed('customers', [
        {
          'id': 'r1',
          'farm_id': 'farm-1',
          'name': 'أحمد',
          'phone': '01',
          'total_debt': 500,
          'created_at': '2026-01-01T00:00:00.000',
          'sync_status': 'synced',
        },
        {
          'id': 'r2',
          'farm_id': 'farm-1',
          'name': 'سامر',
          'phone': '02',
          'total_debt': 0,
          'created_at': '2026-01-02T00:00:00.000',
          'sync_status': 'synced',
        },
      ]);

      final customers = await repo().syncCustomersFromRemote('farm-1');

      expect(customers, hasLength(2));
      expect(customers.map((c) => c.name).toSet(), {'أحمد', 'سامر'});
    });

    test('addCustomer عند انقطاع الشبكة: يبقى pending محلياً بدون خطأ', () async {
      fake.failWrites = true;
      final id = await repo().addCustomer(CustomerModel(
        farmId: 'farm-1',
        name: 'محلي',
        phone: '00',
      ));

      final db = await LocalDatabase.database;
      final row = (await db.query('customers',
              where: 'id = ?', whereArgs: [id] as List))
          .single;
      expect(row['sync_status'], SyncStatus.pending.name);
    });
  });

  group('NotificationRepositoryImpl - الإشعارات', () {
    NotificationRepositoryImpl repo() => NotificationRepositoryImpl(
          remoteDatasource: SupabaseNotificationDatasource(fake),
        );

    test('getActiveNotifications: عبر الإنترنت من البعيد، وعند الانقطاع لغاية []',
        () async {
      fake.seed('app_notifications', [
        {
          'id': 'n1',
          'farm_id': 'farm-1',
          'title': 'تنبيه',
          'level': 'info',
          'is_persistent': false,
          'is_active': true,
          'date': '2026-08-20',
        },
      ]);
      expect(await repo().getActiveNotifications('farm-1'), hasLength(1));

      fake.failReads = true;
      expect(await repo().getActiveNotifications('farm-1'), isEmpty);
    });

    test('إرسال / حذف / تبديل لا يرمي خطأً عند انقطاع الشبكة', () async {
      final r = repo();
      final notification = AppNotificationModel(
        id: 'n10',
        farmId: 'farm-1',
        title: 'فحص',
        level: 'warning',
        isPersistent: false,
        isActive: true,
      );

      fake.failWrites = true;
      await r.sendNotification(notification);
      await r.deleteNotification('n10');
      await r.toggleNotification('n10', false);

      fake.failWrites = false;
      await r.sendNotification(notification);
      expect(fake.calls, isNotEmpty);
    });
  });

  group('FarmRepositoryImpl - المدجنة والإعدادات', () {
    FarmRepositoryImpl repo() => FarmRepositoryImpl(
          remoteDatasource: SupabaseFarmDatasource(fake),
          settingsDao: SettingsDao(),
        );

    test('getFarm من البعيد، وعند الانقطاع يعيد كياناً افتراضياً', () async {
      fake.seed('farms', [
        {'id': 'farm-1', 'name': 'مزرعة الشام'},
      ]);
      final online = await repo().getFarm('farm-1');
      expect(online.name, 'مزرعة الشام');

      fake.failReads = true;
      final offline = await repo().getFarm('farm-1');
      expect(offline.name, 'المدجنة');
      expect(offline.id, 'farm-1');
    });

    test('الإعدادات: قيم افتراضية ثم دورة تخزين/استرجاع', () async {
      final r = repo();
      expect(await r.getCurrency(), 'ل.س');
      expect(await r.getFeedBagWeightKg(), 50.0);
      expect(await r.getEggsPerCarton(), 360);
      expect(await r.getEggsPerTray(), 30);
      expect(await r.getDefaultMortalityRate(), 0.0);

      await r.setCurrency(r'$');
      await r.setFeedBagWeightKg(25);
      await r.setEggsPerCarton(300);
      await r.setEggsPerTray(24);
      await r.setDefaultMortalityRate(2.5);

      expect(await r.getCurrency(), r'$');
      expect(await r.getFeedBagWeightKg(), 25.0);
      expect(await r.getEggsPerCarton(), 300);
      expect(await r.getEggsPerTray(), 24);
      expect(await r.getDefaultMortalityRate(), 2.5);
    });
  });

  group('UserAdminRepositoryImpl - إدارة المستخدمين', () {
    UserAdminRepositoryImpl repo() => UserAdminRepositoryImpl(
          remoteDatasource: SupabaseUserAdminDatasource(fake),
          userDao: UserDao(),
        );

    Map<String, dynamic> userRow(String id, String role) => {
          'id': id,
          'name': 'مستخدم $id',
          'phone': '0$id',
          'role': role,
          'farm_id': 'farm-1',
          'is_active': true,
          'created_at': '2026-01-01T00:00:00.000',
        };

    test('getUsers: من البعيد مع زراعة كاش محلي، وعند الانقطاع من الكاش',
        () async {
      fake.seed('users', [userRow('u1', 'worker'), userRow('u2', 'worker')]);
      final r = repo();

      final users = await r.getUsers('farm-1');
      expect(users, hasLength(2));
      expect(await UserDao().getByFarm('farm-1'), hasLength(2));

      fake.failReads = true;
      final offline = await r.getUsers('farm-1');
      expect(offline, hasLength(2));
    });

    test('createUser يمنع مديراً ثانياً في نفس المدجنة', () async {
      fake.seed('users', [userRow('mgr', 'manager')]);
      expect(
        () => repo().createUser(
          farmId: 'farm-1',
          name: 'مدير جديد',
          phone: '099',
          pin: '1234',
          role: UserRole.manager,
        ),
        throwsA(predicate((e) => '$e'.contains('يوجد مدير بالفعل'))),
      );
    });

    test('createUser (عامل) يستدعي admin_create_user ويرجع المستخدم الجديد',
        () async {
      fake.onRpc = (name, params) {
        if (name == 'admin_create_user') {
          return userRow('u9', 'worker');
        }
        return null;
      };

      final created = await repo().createUser(
        farmId: 'farm-1',
        name: 'عامل',
        phone: '099',
        pin: '1234',
        role: UserRole.worker,
      );

      expect(created.uid, 'u9');
      expect(fake.findCall('rpc admin_create_user'), isTrue);
    });

    test('createUser يفشل بخطأ مقروء عندما ترمي السحابة', () async {
      fake.onRpc = (name, params) {
        throw Exception('duplicate phone');
      };
      expect(
        () => repo().createUser(
          farmId: 'farm-1',
          name: 'عامل',
          phone: '099',
          pin: '1234',
          role: UserRole.worker,
        ),
        throwsA(predicate((e) => '$e'.contains('تعذّر إنشاء المستخدم'))),
      );
    });

    test('getAllUsers / getAllFarms / getSyncHealth عبر RPC', () async {
      fake.onRpc = (name, params) {
        switch (name) {
          case 'admin_select_all_users':
            return [userRow('a1', 'worker')];
          case 'admin_select_all_farms':
            return [
              {'id': 'farm-1', 'name': 'مزرعة الشام'}
            ];
          case 'admin_sync_health':
            return [
              {
                'farm_id': 'farm-1',
                'farm_name': 'مزرعة الشام',
                'device_count': 2,
                'online_devices': 1,
                'offline_devices': 1,
                'pending_conflicts': 3,
                'latest_version': 42,
              }
            ];
        }
        return null;
      };

      expect(await repo().getAllUsers(), hasLength(1));
      final farms = await repo().getAllFarms();
      expect(farms.single.name, 'مزرعة الشام');
      final health = await repo().getSyncHealth();
      expect(health.single.pendingConflicts, 3);
      expect(health.single.latestVersion, 42);
    });

    test('getAllUsers / getAllFarms عند الانقطاع: []', () async {
      final r = repo();
      fake.onRpc = (name, params) => throw Exception('down');
      expect(await r.getAllUsers(), isEmpty);
      expect(await r.getAllFarms(), isEmpty);
      expect(await r.getSyncHealth(), isEmpty);
    });

    test('updateUser / resetPin / deleteUser تُمرّر عبر RPC وتُغلّف الفشل',
        () async {
      final r = repo();
      await r.updateUser(uid: 'u1', name: 'جديد');
      await r.resetPin(uid: 'u1', newPin: '9999');
      await r.deleteUser('u1');
      expect(fake.findCall('rpc admin_update_user'), isTrue);
      expect(fake.findCall('rpc admin_reset_pin'), isTrue);
      expect(fake.findCall('rpc admin_delete_user'), isTrue);

      fake.onRpc = (name, params) => throw Exception('down');
      expect(
        () => r.updateUser(uid: 'u1'),
        throwsA(predicate((e) => '$e'.contains('تعذّر تعديل المستخدم'))),
      );
      expect(
        () => r.deleteUser('u1'),
        throwsA(predicate((e) => '$e'.contains('تعذّر حذف المستخدم'))),
      );
    });
  });
}

/// استيراد CustomerDao لاستخدامه في DispatchRepositoryImpl.
class CustomerDao extends package:data/daos/CustomerDao {}