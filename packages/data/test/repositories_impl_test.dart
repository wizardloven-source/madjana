import 'dart:io';

import 'package:core/core.dart';
import 'package:data/src/datasources/local/daos/dispatch_dao.dart';
import 'package:data/src/datasources/local/daos/egg_production_dao.dart';
import 'package:data/src/datasources/local/daos/flock_dao.dart';
import 'package:data/src/datasources/local/daos/payment_dao.dart';
import 'package:data/src/datasources/local/local_database.dart';
import 'package:data/src/datasources/remote/supabase_egg_datasource.dart';
import 'package:data/src/datasources/remote/supabase_flock_datasource.dart';
import 'package:data/src/datasources/remote/supabase_payment_datasource.dart';
import 'package:data/src/repositories/egg_production_repository_impl.dart';
import 'package:data/src/repositories/flock_repository_impl.dart';
import 'package:data/src/repositories/impl/conflict_repository_impl.dart';
import 'package:data/src/repositories/payment_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/db_harness.dart';
import 'support/fake_supabase_api.dart';

void main() {
  setUpAll(enableFfiDatabase);

  late Directory dbDir;
  late FakeSupabaseApi fake;

  setUp(() async {
    dbDir = await createDbHarness('repos_impl');
    fake = FakeSupabaseApi();
  });

  tearDown(() => tearDownDbHarness(dbDir));

  EggProductionModel eggRecord({
    String? id,
    String farmId = 'farm-1',
    String flockId = 'flock-1',
    DateTime? date,
  }) {
    return EggProductionModel(
      id: id,
      farmId: farmId,
      flockId: flockId,
      date: date ?? DateTime(2026, 8, 20),
      cartons: 2,
      trays: 4,
      looseEggs: 10,
      workerId: 'worker-1',
    );
  }

  FlockModel flock({String id = 'flock-1', String? status}) {
    return FlockModel(
      id: id,
      farmId: 'farm-1',
      breed: 'لومان براون',
      startDate: DateTime(2026, 1, 15),
      initialCount: 5000,
      currentCount: 4900,
      status: FlockStatus.values.firstWhere(
        (e) => e.name == status,
        orElse: () => FlockStatus.active,
      ),
    );
  }

  group('EggProductionRepositoryImpl - حفظ محلي وتزامن', () {
    test('saveLocal يحفظ في SQLite فقط ويتركه pending مع سجل مزامنة', () async {
      final repo = EggProductionRepositoryImpl(
        localDao: EggProductionDao(),
        remoteDatasource: SupabaseEggDatasource(fake),
      );

      await repo.saveLocal(eggRecord());

      expect(await repo.getPendingCount(), 1);
      final records = await repo.getAllRecords(farmId: 'farm-1');
      expect(records, hasLength(1));
      expect(records.first.farmId, 'farm-1');
      expect(records.first.syncStatus, SyncStatus.pending);

      // لم يلمس السحابة إطلاقاً
      expect(fake.tables['egg_production'] ?? [], isEmpty);
    });

    test('syncPendingRecords يرفع السجلات المعلقة ويحوّلها إلى synced', () async {
      final repo = EggProductionRepositoryImpl(
        localDao: EggProductionDao(),
        remoteDatasource: SupabaseEggDatasource(fake),
      );
      await repo.saveLocal(eggRecord());
      await repo.saveLocal(eggRecord());

      await repo.syncPendingRecords();

      expect(await repo.getPendingCount(), 0);
      final records = await repo.getAllRecords(farmId: 'farm-1');
      expect(records, everyElement(predicate(
          (EggProductionModel r) => r.syncStatus == SyncStatus.synced)));
      expect(fake.tables['egg_production'], hasLength(2));
    });

    test('syncPendingRecords عند فشل كامل يعلّم السجلات failed', () async {
      final repo = EggProductionRepositoryImpl(
        localDao: EggProductionDao(),
        remoteDatasource: SupabaseEggDatasource(fake),
      );
      await repo.saveLocal(eggRecord());

      fake.failWrites = true;
      await repo.syncPendingRecords();

      expect(await repo.getPendingCount(), 0);
      final records = await repo.getAllRecords(farmId: 'farm-1');
      expect(records.single.syncStatus, SyncStatus.failed);
    });

    test('syncPendingRecords بلا سجلات معلقة لا يفعل شيئاً', () async {
      final repo = EggProductionRepositoryImpl(
        localDao: EggProductionDao(),
        remoteDatasource: SupabaseEggDatasource(fake),
      );
      await repo.syncPendingRecords();
      expect(fake.calls, isEmpty);
    });

    test('deleteRecord يحذف محلياً والبعيد معاً', () async {
      final repo = EggProductionRepositoryImpl(
        localDao: EggProductionDao(),
        remoteDatasource: SupabaseEggDatasource(fake),
      );
      await repo.saveLocal(eggRecord());
      final id = (await repo.getAllRecords(farmId: 'farm-1')).single.id!;

      await repo.deleteRecord(id);

      expect(await repo.getAllRecords(), isEmpty);
      expect(fake.findCall('delete egg_production'), isTrue);
      expect(fake.tables['egg_production'] ?? [], isEmpty);
    });

    test('deleteRecord عند انقطاع السحابة: يبقى محذوفاً محلياً دون خطأ', () async {
      final repo = EggProductionRepositoryImpl(
        localDao: EggProductionDao(),
        remoteDatasource: SupabaseEggDatasource(fake),
      );
      await repo.saveLocal(eggRecord());
      final id = (await repo.getAllRecords(farmId: 'farm-1')).single.id!;

      fake.failWrites = true;
      await repo.deleteRecord(id);

      expect(await repo.getAllRecords(), isEmpty);
    });
  });

  group('PaymentRepositoryImpl - قبض المدير', () {
    PaymentModel payment({String? dispatchId, double amountPaid = 100}) {
      return PaymentModel(
        farmId: 'farm-1',
        dispatchId: dispatchId,
        customerId: 'cust-1',
        date: DateTime(2026, 8, 20),
        pricePerCarton: 360,
        totalDue: 720,
        amountPaid: amountPaid,
        paymentMethod: PaymentMethod.cash,
        managerId: 'manager-1',
      );
    }

    test('save يحفظ محلياً ويرفع للبعيد ويحدث حالة فاتورة التخريج', () async {
      final dispatchId = await DispatchDao().insert(DispatchModel(
            farmId: 'farm-1', date: DateTime(2026, 8, 20), customerId: 'c1',
            cartons: 2, trays: 0, workerId: 'w1',
          ));
      final repo = PaymentRepositoryImpl(
        paymentDao: PaymentDao(),
        dispatchDao: DispatchDao(),
        remoteDatasource: SupabasePaymentDatasource(fake),
      );

      await repo.save(payment(dispatchId: dispatchId));

      // محلياً: منفصل pending
      final db = await LocalDatabase.database;
      final rows = await db.query('payments');
      expect(rows, hasLength(1));
      expect(rows.first['sync_status'], SyncStatus.pending.name);

      // البعيد: سطر مدرج
      expect(fake.tables['payments'], hasLength(1));

      // حالة الفاتورة partial (قبض جزئي)
      final dispatch =
          (await db.query('egg_dispatch', where: 'id = ?', whereArgs: [dispatchId] as List))
              .single;
      expect(dispatch['payment_status'], PaymentStatus.partial.name);
    });

    test('save عند انقطاع الشبكة يعمل دون خطأ ويبقى السجل محلياً', () async {
      final repo = PaymentRepositoryImpl(
        paymentDao: PaymentDao(),
        dispatchDao: DispatchDao(),
        remoteDatasource: SupabasePaymentDatasource(fake),
      );
      fake.failWrites = true;

      await repo.save(payment());

      final db = await LocalDatabase.database;
      expect(await db.query('payments'), hasLength(1));
    });

    test('getAll: عبر الإنترنت من البعيد، وعند الانقطاع من المحلي', () async {
      final ds = SupabasePaymentDatasource(fake);
      final repo = PaymentRepositoryImpl(
        paymentDao: PaymentDao(),
        dispatchDao: DispatchDao(),
        remoteDatasource: ds,
      );
      // حفظ أثناء انقطاع: محلي فقط، البعيد يبقى فارغاً
      fake.failWrites = true;
      await repo.save(payment());
      fake.failWrites = false;
      fake.clearCalls();

      // المزامنة ناجحة: البعيد فارغ
      fake.failReads = false;
      final online = await repo.getAll(farmId: 'farm-1');
      expect(online, isEmpty);

      // انقطاع: يُرتجع المحلي
      fake.failReads = true;
      final offline = await repo.getAll(farmId: 'farm-1');
      expect(offline, hasLength(1));
      expect(offline.first.amountPaid, 100);
    });

    test('getTotalOutstanding و getTotalCollected يحسبان من المحلي', () async {
      final repo = PaymentRepositoryImpl(
        paymentDao: PaymentDao(),
        dispatchDao: DispatchDao(),
        remoteDatasource: SupabasePaymentDatasource(fake),
      );
      await repo.save(payment(amountPaid: 100));
      await repo.save(payment(amountPaid: 720));

      expect(await repo.getTotalOutstanding(farmId: 'farm-1'), 620);
      expect(await repo.getTotalCollected(farmId: 'farm-1'), 820);
    });
  });

  group('FlockRepositoryImpl - قطعان', () {
    test('getFlocks عبر الإنترنت: يُرجع البعيد ويحفظه كاش محلي', () async {
      fake.seed('flocks', [
        {
          'id': 'fl-1',
          'farm_id': 'farm-1',
          'breed': 'هاي لاين',
          'start_date': '2026-02-01',
          'initial_count': 3000,
          'current_count': 2990,
          'status': 'active',
          'sections_count': 1,
        },
      ]);
      final repo = FlockRepositoryImpl(
        localDao: FlockDao(),
        remoteDatasource: SupabaseFlockDatasource(fake),
      );

      final flocks = await repo.getFlocks('farm-1');
      expect(flocks, hasLength(1));
      expect(flocks.first.breed, 'هاي لاين');

      // الكاش المحلي حُدّث
      final local = await FlockDao().getByFarm('farm-1');
      expect(local, hasLength(1));
      expect(local.first.id, 'fl-1');
    });

    test('getFlocks عند الانقطاع: يعيد القطعان النشطة محلياً (includeEnded=false)',
        () async {
      final dao = FlockDao();
      await dao.insert(flock(id: 'local-1'));
      await dao.insert(flock(id: 'local-2', status: 'depleted'));

      fake.failReads = true;
      final repo = FlockRepositoryImpl(
        localDao: dao,
        remoteDatasource: SupabaseFlockDatasource(fake),
      );

      final flocks = await repo.getFlocks('farm-1', includeEnded: false);
      expect(flocks.map((f) => f.id), ['local-1']);
    });

    test('createFlock: حفظ محلي أولاً ثم رفع للبعيد', () async {
      final dao = FlockDao();
      final repo = FlockRepositoryImpl(
        localDao: dao,
        remoteDatasource: SupabaseFlockDatasource(fake),
      );
      await repo.createFlock(flock(id: 'new-fl'));

      expect(await dao.getByFarm('farm-1'), hasLength(1));
      expect(fake.tables['flocks'], hasLength(1));
      expect(fake.tables['flocks']!.first['id'], 'new-fl');
    });

    test('createFlock عند انقطاع الشبكة: يبقى محلياً فقط', () async {
      final dao = FlockDao();
      final repo = FlockRepositoryImpl(
        localDao: dao,
        remoteDatasource: SupabaseFlockDatasource(fake),
      );
      fake.failWrites = true;

      await repo.createFlock(flock(id: 'offline-fl'));

      expect(await dao.getByFarm('farm-1'), hasLength(1));
      expect(fake.tables['flocks'] ?? [], isEmpty);
    });

    test('endFlock: إنهاء محلي + بعيد', () async {
      final dao = FlockDao();
      await dao.insert(flock(id: 'fl-end'));
      final repo = FlockRepositoryImpl(
        localDao: dao,
        remoteDatasource: SupabaseFlockDatasource(fake),
      );

      await repo.endFlock('fl-end');

      // انتهى: لم يعد ضمن النشطة
      expect(await dao.getByFarm('farm-1'), isEmpty);
      expect(fake.findCall('update flocks'), isTrue);
    });
  });

  group('ConflictRepositoryImpl - التعارضات', () {
    ConflictModel conflict(String id, {String status = 'pending'}) {
      return ConflictModel(
        id: id,
        tableName: 'egg_production',
        recordId: 'rec-$id',
        clientData: {'cartons': 5},
        serverData: {'cartons': 7},
        status: status,
        createdAt: DateTime(2026, 8, 20),
        suggestedAction: 'merge',
      );
    }

    test('addConflict ثم getAllConflicts مع الترشيح', () async {
      final repo = const ConflictRepositoryImpl();
      await repo.addConflict(conflict('c1'));
      await repo.addConflict(conflict('c2'));
      await repo.addConflict(
          conflict('c3', status: 'resolved'));

      final all = await repo.getAllConflicts();
      expect(all, hasLength(3));

      final pending = await repo.getAllConflicts(status: 'pending');
      expect(pending, hasLength(2));

      final byTable = await repo.getAllConflicts(tableName: 'egg_production');
      expect(byTable, hasLength(3));
      expect(await repo.getAllConflicts(tableName: 'payments'), isEmpty);
    });

    test('getConflictById يفك تشفير بيانات العميل والخادم', () async {
      final repo = const ConflictRepositoryImpl();
      await repo.addConflict(conflict('c9'));

      final found = await repo.getConflictById('c9');
      expect(found, isNotNull);
      expect(found!.clientData['cartons'], 5);
      expect(found.serverData?['cartons'], 7);
      expect(found.tableName, 'egg_production');
      expect(found.suggestedAction, 'merge');

      expect(await repo.getConflictById('missing'), isNull);
    });

    test('resolveConflict و ignoreConflict يحدّثان الحالة', () async {
      final repo = const ConflictRepositoryImpl();
      await repo.addConflict(conflict('c-resolve'));
      await repo.addConflict(conflict('c-ignore'));

      await repo.resolveConflict('c-resolve', resolution: 'client_wins');
      await repo.ignoreConflict('c-ignore');

      var resolved = await repo.getConflictById('c-resolve');
      expect(resolved!.status, 'resolved');

      var ignored = await repo.getConflictById('c-ignore');
      expect(ignored!.status, 'ignored');

      // التحقق من أعمدة القرار على مستوى الصف
      final db = await LocalDatabase.database;
      final row = (await db.query('conflicts',
              where: 'id = ?', whereArgs: <Object>['c-resolve']))
          .single;
      expect(row['resolution'], 'client_wins');
      expect(row['resolved_at'], isNotNull);

      expect(await repo.getAllConflicts(status: 'pending'), isEmpty);
    });
  });
}