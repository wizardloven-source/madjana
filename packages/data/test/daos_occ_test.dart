import 'dart:convert';
import 'dart:io';

import 'package:core/core.dart';
import 'package:data/src/datasources/local/daos/dispatch_dao.dart';
import 'package:data/src/datasources/local/daos/egg_production_dao.dart';
import 'package:data/src/datasources/local/daos/expense_dao.dart';
import 'package:data/src/datasources/local/daos/feed_dao.dart';
import 'package:data/src/datasources/local/daos/flock_dao.dart';
import 'package:data/src/datasources/local/daos/inventory_dao.dart';
import 'package:data/src/datasources/local/daos/medication_dao.dart';
import 'package:data/src/datasources/local/daos/mortality_dao.dart';
import 'package:data/src/datasources/local/daos/payment_dao.dart';
import 'package:data/src/datasources/local/local_database.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/db_harness.dart';

void main() {
  setUpAll(enableFfiDatabase);

  late Directory dbDir;

  setUp(() async {
    dbDir = await createDbHarness('daos_occ');
  });

  tearDown(() => tearDownDbHarness(dbDir));

  /// جلب السجلات المعلقة من sync_queue لسجل معين.
  Future<List<Map<String, dynamic>>> pendingFor(String recordId) async {
    final db = await LocalDatabase.database;
    return db.query(
      'sync_queue',
      where: 'record_id = ?',
      whereArgs: [recordId],
      orderBy: 'created_at ASC',
    );
  }

  Map<String, dynamic> payloadOf(Map<String, dynamic> row) =>
      jsonDecode(row['payload'] as String) as Map<String, dynamic>;

  group('EggProductionDao - OCC', () {
    test('insert يسجّل INSERT فقط بأعمدة التشغيل (بدون version)', () async {
      final dao = EggProductionDao();
      final id = await dao.insert(EggProductionModel(
            farmId: 'farm-1',
            flockId: 'flock-1',
            date: DateTime(2026, 8, 20),
            cartons: 2,
            trays: 5,
            looseEggs: 10,
            brokenEggs: 1,
            dirtyEggs: 2,
            trayWeightKg: 24.5,
            sectionNo: 3,
            workerId: 'worker-1',
          ));

      final rows = await pendingFor(id);
      expect(rows, hasLength(1));
      expect(rows.first['action'], 'INSERT');
      final payload = payloadOf(rows.first);
      // الأعمدة النظامية تُشرف
      for (final c in ['id', 'farm_id', 'version', 'sync_status', 'created_at', 'updated_at']) {
        expect(payload.containsKey(c), isFalse, reason: 'payload فيه $c');
      }
      expect(payload['flock_id'], 'flock-1');
      expect(payload['date'], '2026-08-20');
      expect(payload['cartons'], 2);
      expect(payload['worker_id'], 'worker-1');
      expect(payload['section_no'], 3);
      // INSERT لا يحمل previous_version
      expect(payload.containsKey('previous_version'), isFalse);
    });

    test('delete يسجّل DELETE مع previous_version لأحدث إصدار محلي', () async {
      final dao = EggProductionDao();
      final id = await dao.insert(EggProductionModel(
            farmId: 'farm-1',
            flockId: 'flock-1',
            date: DateTime(2026, 8, 20),
            cartons: 2,
            trays: 5,
            looseEggs: 10,
            workerId: 'worker-1',
          ));

      // رفع version محليًا لمحاكاة إصدار متقدم
      final db = await LocalDatabase.database;
      await db.rawUpdate(
        'UPDATE egg_production SET version = 7 WHERE id = ?',
        [id],
      );

      await dao.delete(id);

      final rows = await pendingFor(id);
      expect(rows, hasLength(2));
      final deletePayload = payloadOf(rows.last);
      expect(rows.last['action'], 'DELETE');
      expect(deletePayload['previous_version'], 7);
      // هوية السجل تُنقل عبر عمود record_id، وليس داخل الـ payload
      expect(deletePayload.containsKey('id'), isFalse);

      // السجل محذوف محليًا
      final remaining =
          await db.query('egg_production', where: 'id = ?', whereArgs: [id]);
      expect(remaining, isEmpty);
    });

    test('delete لسجل غير موجود يسجّل previous_version = 1', () async {
      final dao = EggProductionDao();
      await dao.delete('missing-id');

      final rows = await pendingFor('missing-id');
      expect(rows, hasLength(1));
      expect(rows.first['action'], 'DELETE');
      expect(payloadOf(rows.first)['previous_version'], 1);
    });

    test('getPendingRecords يرجع السجلات المعلقة فقط بترتيب زمني', () async {
      final dao = EggProductionDao();
      final id1 = await dao.insert(EggProductionModel(
            farmId: 'farm-1', flockId: 'flock-1', date: DateTime(2026, 8, 1),
            cartons: 1, trays: 0, looseEggs: 0, workerId: 'w1',
          ));
      final id2 = await dao.insert(EggProductionModel(
            farmId: 'farm-1', flockId: 'flock-1', date: DateTime(2026, 8, 2),
            cartons: 2, trays: 0, looseEggs: 0, workerId: 'w1',
          ));
      await dao.updateSyncStatus(id1, SyncStatus.synced);

      final pending = await dao.getPendingRecords();
      expect(pending.map((r) => r.id), [id2]);
      expect(await dao.countPending(), 1);
    });
  });

  group('PaymentDao - OCC (تحديث وحذف)', () {
    Future<String> insertPayment() async {
      final dao = PaymentDao();
      return dao.insert(PaymentModel(
            farmId: 'farm-1',
            customerId: 'cust-1',
            date: DateTime(2026, 8, 20),
            pricePerCarton: 360,
            totalDue: 720,
            amountPaid: 100,
            paymentMethod: PaymentMethod.cash,
            managerId: 'manager-1',
          ));
    }

    test('update يسجّل UPDATE مع previous_version = 1 (الإصدار الأول)', () async {
      final dao = PaymentDao();
      final id = await insertPayment();

      await dao.update(id, PaymentModel(
            farmId: 'farm-1',
            customerId: 'cust-1',
            date: DateTime(2026, 8, 20),
            pricePerCarton: 360,
            totalDue: 720,
            amountPaid: 500,
            paymentMethod: PaymentMethod.cash,
            managerId: 'manager-1',
          ));

      final rows = await pendingFor(id);
      expect(rows, hasLength(2));
      final updatePayload = payloadOf(rows.last);
      expect(rows.last['action'], 'UPDATE');
      expect(updatePayload['previous_version'], 1);
      expect(updatePayload['amount_paid'], 500);
    });

    test('delete يسجّل DELETE مع previous_version بعد تحديث سابق', () async {
      final dao = PaymentDao();
      final id = await insertPayment();
      final db = await LocalDatabase.database;
      await db.rawUpdate('UPDATE payments SET version = 4 WHERE id = ?', [id]);

      await dao.delete(id);

      final rows = await pendingFor(id);
      expect(rows, hasLength(2));
      expect(payloadOf(rows.last)['previous_version'], 4);
    });

    test('getTotalCollected يحسب الإجمالي الصحيح', () async {
      final dao = PaymentDao();
      await dao.insert(PaymentModel(
            farmId: 'farm-1', customerId: 'c1', date: DateTime(2026, 8, 1),
            pricePerCarton: 360, totalDue: 720, amountPaid: 200,
            paymentMethod: PaymentMethod.cash, managerId: 'm1',
          ));
      await dao.insert(PaymentModel(
            farmId: 'farm-1', customerId: 'c2', date: DateTime(2026, 8, 2),
            pricePerCarton: 360, totalDue: 360, amountPaid: 360,
            paymentMethod: PaymentMethod.transfer, managerId: 'm1',
          ));
      expect(await dao.getTotalCollected(), 560);
    });
  });

  group('InventoryDao - OCC (saveItem للعنصر)', () {
    test('إدخال أولي INSERT ثم تحديث UPDATE مع previous_version', () async {
      final dao = InventoryDao();
      const itemId = 'item-1';

      await dao.saveItem(InventoryItemModel(
            id: itemId,
            farmId: 'farm-1',
            name: 'خيط',
            unit: InventoryUnit.kg,
            quantity: 10,
            lowStockThreshold: 2,
          ));

      var rows = await pendingFor(itemId);
      expect(rows, hasLength(1));
      expect(rows.first['action'], 'INSERT');

      await dao.saveItem(InventoryItemModel(
            id: itemId,
            farmId: 'farm-1',
            name: 'خيط',
            unit: InventoryUnit.kg,
            quantity: 8,
            lowStockThreshold: 2,
          ));

      rows = await pendingFor(itemId);
      expect(rows, hasLength(2));
      expect(rows.last['action'], 'UPDATE');
      final updatePayload = payloadOf(rows.last);
      expect(updatePayload['previous_version'], 1);
      // الكمية محلية فقط ولا تُرفع في المزامنة (حسب تصميم DAO)
      expect(updatePayload.containsKey('quantity'), isFalse);
      // الكمية تُحفظ محليًا في الجدول
      final item = await dao.getById(itemId);
      expect(item!.quantity, 8);
    });

    test('deleteItem يسجّل DELETE مع previous_version', () async {
      final dao = InventoryDao();
      const itemId = 'item-2';
      await dao.saveItem(InventoryItemModel(
            id: itemId, farmId: 'farm-1', name: 'قطن',
          ));

      await dao.deleteItem(itemId);

      final rows = await pendingFor(itemId);
      expect(rows, hasLength(2));
      expect(rows.last['action'], 'DELETE');
      expect(payloadOf(rows.last)['previous_version'], 1);
    });
  });

  group('OCC عبر بقية DAOs (قنوات البيانات التشغيلية)', () {
    test('MortalityDao.delete يحمل أحدث نسخة محلية في previous_version', () async {
      final dao = MortalityDao();
      final id = await dao.insert(MortalityModel(
            farmId: 'farm-1',
            flockId: 'flock-1',
            date: DateTime(2026, 8, 20),
            count: 3,
            reason: MortalityReason.other,
            workerId: 'worker-1',
          ));
      final db = await LocalDatabase.database;
      await db.rawUpdate('UPDATE mortality SET version = 5 WHERE id = ?', [id]);

      await dao.delete(id);

      final rows = await pendingFor(id);
      expect(rows, hasLength(2));
      expect(rows.last['action'], 'DELETE');
      expect(payloadOf(rows.last)['previous_version'], 5);
      expect(payloadOf(rows.last).containsKey('id'), isFalse);
      final remaining =
          await db.query('mortality', where: 'id = ?', whereArgs: [id]);
      expect(remaining, isEmpty);
    });

    test('FlockDao.markEnded يُسجّل UPDATE بآخر نسخة محلية وحالة depleted', () async {
      final dao = FlockDao();
      final flock = FlockModel(
        id: 'flock-occ-1',
        farmId: 'farm-1',
        breed: 'برايل',
        startDate: DateTime(2026, 7, 1),
        initialCount: 500,
        currentCount: 480,
      );
      await dao.insert(flock);
      final db = await LocalDatabase.database;
      await db.rawUpdate('UPDATE flocks SET version = 3 WHERE id = ?', [flock.id]);

      await dao.markEnded(flock.id);

      final rows = await pendingFor(flock.id);
      // INSERT (من saveAll/insert) + UPDATE
      final updateRow = rows.firstWhere((r) => r['action'] == 'UPDATE');
      expect(updateRow['record_id'], flock.id);
      expect(updateRow['action'], 'UPDATE');
      final payload = payloadOf(updateRow);
      expect(payload['previous_version'], 3);
      expect(payload['status'], FlockStatus.depleted.name);

      final stored = (await db.query('flocks',
          where: 'id = ?', whereArgs: [flock.id])).first;
      expect(stored['status'], FlockStatus.depleted.name);
    });

    test('ExpenseDao.update يُسجّل UPDATE بآخر نسخة محلية وقيمته المحدّثة', () async {
      final dao = ExpenseDao();
      final id = await dao.insert(ExpenseModel(
            farmId: 'farm-1',
            date: DateTime(2026, 8, 20),
            category: ExpenseCategory.other,
            amount: 100,
          ));
      final db = await LocalDatabase.database;
      await db.rawUpdate('UPDATE expenses SET version = 2 WHERE id = ?', [id]);

      await dao.update(id, ExpenseModel(
            farmId: 'farm-1',
            date: DateTime(2026, 8, 20),
            category: ExpenseCategory.other,
            amount: 999,
          ));

      final rows = await pendingFor(id);
      final updateRow = rows.firstWhere((r) => r['action'] == 'UPDATE');
      expect(updateRow['record_id'], id);
      final payload = payloadOf(updateRow);
      expect(payload['previous_version'], 2);
      expect(payload['amount'], 999);
      final stored = (await db.query('expenses',
          where: 'id = ?', whereArgs: [id])).first;
      expect(stored['amount'], 999);
    });

    test('ExpenseDao.delete يُسجّل DELETE بآخر نسخة محلية', () async {
      final dao = ExpenseDao();
      final id = await dao.insert(ExpenseModel(
            farmId: 'farm-1',
            date: DateTime(2026, 8, 20),
            category: ExpenseCategory.feed,
            amount: 250,
          ));
      final db = await LocalDatabase.database;
      await db.rawUpdate('UPDATE expenses SET version = 4 WHERE id = ?', [id]);

      await dao.delete(id);

      final rows = await pendingFor(id);
      expect(rows.last['action'], 'DELETE');
      expect(payloadOf(rows.last)['previous_version'], 4);
      final remaining =
          await db.query('expenses', where: 'id = ?', whereArgs: [id]);
      expect(remaining, isEmpty);
    });

    test('MedicationDao.delete يُسجّل DELETE بآخر نسخة محلية', () async {
      final dao = MedicationDao();
      final id = await dao.insert(MedicationModel(
            farmId: 'farm-1',
            date: DateTime(2026, 8, 20),
            type: MedicationType.drug,
            medicineName: 'أموكسيسيلين',
            dosage: '1/1000',
            administrationRoute: AdministrationRoute.water,
            workerId: 'worker-1',
          ));
      final db = await LocalDatabase.database;
      await db.rawUpdate('UPDATE medications SET version = 6 WHERE id = ?', [id]);

      await dao.delete(id);

      final rows = await pendingFor(id);
      expect(rows.last['action'], 'DELETE');
      expect(payloadOf(rows.last)['previous_version'], 6);
      final remaining =
          await db.query('medications', where: 'id = ?', whereArgs: [id]);
      expect(remaining, isEmpty);
    });

    test('DispatchDao.insert يُسجّل في الطابور دون فشل (updated_at إلزامي)', () async {
      final dao = DispatchDao();
      final id = await dao.insert(DispatchModel(
            farmId: 'farm-1',
            date: DateTime(2026, 8, 20),
            customerId: 'cust-1',
            cartons: 10,
            trays: 2,
            workerId: 'worker-1',
          ));
      final rows = await pendingFor(id);
      expect(rows, hasLength(1));
      expect(rows.first['action'], 'INSERT');
      final payload = payloadOf(rows.first);
      expect(payload['cartons'], 10);
      expect(payload['customer_id'], 'cust-1');
      // هوية السجل عبر record_id وليس داخل الـ payload
      expect(payload.containsKey('id'), isFalse);

      final db = await LocalDatabase.database;
      final stored = await db.query('egg_dispatch',
          where: 'id = ?', whereArgs: [id]);
      expect(stored, hasLength(1));
    });

    test('FeedDao.insertConsumption يُسجّل في الطابور دون فشل (updated_at إلزامي)', () async {
      final dao = FeedDao();
      final id = await dao.insertConsumption(FeedConsumptionModel(
            farmId: 'farm-1',
            date: DateTime(2026, 8, 20),
            entryMode: FeedEntryMode.bags,
            bagsCount: 5,
            quantityKg: 150,
            workerId: 'worker-1',
          ));
      final rows = await pendingFor(id);
      expect(rows, hasLength(1));
      expect(rows.first['action'], 'INSERT');
      final payload = payloadOf(rows.first);
      expect(payload['quantity_kg'], 150);
      expect(payload['entry_mode'], FeedEntryMode.bags.name);
      expect(payload.containsKey('id'), isFalse);
    });

    test('FeedDao.insertReceived يُسجّل في الطابور دون فشل (updated_at إلزامي)', () async {
      final dao = FeedDao();
      final id = await dao.insertReceived({
        'farm_id': 'farm-1',
        'date': '2026-08-20',
        'entry_mode': 'kg',
        'quantity': 10,
        'quantity_kg': 500,
        'feed_type': 'starter',
        'supplier': 'مورد',
        'invoice_number': 'IN-1',
        'price_per_kg': 25,
        'notes': null,
        'section_no': 1,
        'worker_id': 'worker-1',
      });
      final rows = await pendingFor(id);
      expect(rows, hasLength(1));
      expect(rows.first['action'], 'INSERT');
      expect(payloadOf(rows.first)['quantity_kg'], 500);
      expect(payloadOf(rows.first).containsKey('id'), isFalse);
    });
  });
}