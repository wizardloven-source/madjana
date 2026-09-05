import 'dart:convert';
import 'dart:io';

import 'package:core/core.dart';
import 'package:data/src/datasources/local/daos/customer_dao.dart';
import 'package:data/src/datasources/local/daos/dispatch_request_dao.dart';
import 'package:data/src/datasources/local/daos/notes_dao.dart';
import 'package:data/src/datasources/local/daos/opening_balance_dao.dart';
import 'package:data/src/datasources/local/daos/reminders_dao.dart';
import 'package:data/src/datasources/local/daos/session_dao.dart';
import 'package:data/src/datasources/local/daos/settings_dao.dart';
import 'package:data/src/datasources/local/daos/sync_queue_dao.dart';
import 'package:data/src/datasources/local/daos/user_dao.dart';
import 'package:data/src/datasources/local/local_database.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/db_harness.dart';

void main() {
  setUpAll(enableFfiDatabase);

  late Directory dbDir;

  setUp(() async {
    dbDir = await createDbHarness('daos_rest');
  });

  tearDown(() => tearDownDbHarness(dbDir));

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

  group('CustomerDao - Offline-first', () {
    Future<CustomerModel> sample({String? id}) => Future.value(CustomerModel(
          id: id,
          farmId: 'farm-1',
          name: 'محمد',
          phone: '0100',
          notes: 'عميل دائم',
          totalDebt: 120.5,
        ));

    test('insert يحفظ محلياً ويسجّل INSERT بدون أعمدة نظامية في الـ payload',
        () async {
      final dao = CustomerDao();
      final id = await dao.insert(await sample());

      final rows = await pendingFor(id);
      expect(rows, hasLength(1));
      expect(rows.first['action'], 'INSERT');

      final payload = payloadOf(rows.first);
      for (final c in ['id', 'farm_id', 'sync_status', 'created_at', 'updated_at']) {
        expect(payload.containsKey(c), isFalse, reason: 'payload فيه $c');
      }
      expect(payload['name'], 'محمد');
      expect(payload['phone'], '0100');
      expect(payload.containsKey('total_debt'), isFalse);
    });

    test('getByFarm يرجع زبائن المزرعة بترتيب الاسم', () async {
      final dao = CustomerDao();
      await dao.insert(CustomerModel(farmId: 'farm-1', name: 'زيد', phone: '1'));
      await dao.insert(CustomerModel(farmId: 'farm-1', name: 'علي', phone: '2'));
      await dao.insert(CustomerModel(farmId: 'farm-2', name: 'أحمد', phone: '3'));

      final farm1 = await dao.getByFarm('farm-1');
      // ترتيب ثنائي (code point): ز < ع، لذا زيد أولاً
      expect(farm1.map((c) => c.name), ['زيد', 'علي']);
      expect(await dao.getByFarm('farm-2'), hasLength(1));
    });

    test('مزامنة: countPending/getPendingRecords/updateSyncStatus', () async {
      final dao = CustomerDao();
      final id1 = await dao.insert(
          CustomerModel(farmId: 'farm-1', name: 'أ', phone: '1'));
      final id2 = await dao.insert(
          CustomerModel(farmId: 'farm-1', name: 'ب', phone: '2'));

      expect(await dao.countPending(), 2);
      final pending = await dao.getPendingRecords();
      expect(pending.map((c) => c.id), containsAll([id1, id2]));

      await dao.updateSyncStatus(id1, SyncStatus.synced);
      expect(await dao.countPending(), 1);
      expect((await dao.getPendingRecords()).single.id, id2);
    });

    test('upsertFromRemote يستبدل السجل مع إبقاء state = synced', () async {
      final dao = CustomerDao();
      final id = await dao.insert(
          CustomerModel(farmId: 'farm-1', name: 'محلي', phone: '1'));
      await dao.updateSyncStatus(id, SyncStatus.pending);

      await dao.upsertFromRemote(CustomerModel(
          id: id, farmId: 'farm-1', name: 'سحابة', phone: '9', totalDebt: 5));

      final db = await LocalDatabase.database;
      final row = (await db.query('customers',
              where: 'id = ?', whereArgs: [id] as List)).single;
      expect(row['name'], 'سحابة');
      expect(row['sync_status'], SyncStatus.synced.name);
      expect(row['total_debt'], 5);
    });

    test('update يسجّل UPDATE مع previous_version ثم delete يسجّل DELETE',
        () async {
      final dao = CustomerDao();
      final id = await dao.insert(
          CustomerModel(farmId: 'farm-1', name: 'محمد', phone: '1'));
      final db = await LocalDatabase.database;
      await db.rawUpdate('UPDATE customers SET version = 3 WHERE id = ?', [id]);

      await dao.update(CustomerModel(
          id: id, farmId: 'farm-1', name: 'محمد2', phone: '2'));
      await dao.deleteById(id);

      final rows = await pendingFor(id);
      expect(rows, hasLength(3));
      expect(rows[1]['action'], 'UPDATE');
      expect(payloadOf(rows[1])['previous_version'], 3);
      expect(payloadOf(rows[1])['name'], 'محمد2');
      expect(rows[2]['action'], 'DELETE');
      expect(payloadOf(rows[2])['previous_version'], 3);

      final remaining =
          await db.query('customers', where: 'id = ?', whereArgs: [id] as List);
      expect(remaining, isEmpty);
    });
  });

  group('UserDao - كاش المستخدمين', () {
    test('upsertAll يدرج الجديد ويستبدل الموجود ويحذف الغائبين', () async {
      final dao = UserDao();
      const farm = 'farm-1';
      await dao.upsertAll(farm, [
        UserModel(uid: 'u1', name: 'أ', phone: '1', role: UserRole.worker,
            farmId: farm, createdAt: DateTime(2026, 1, 1)),
        UserModel(uid: 'u2', name: 'ب', phone: '2', role: UserRole.manager,
            farmId: farm, createdAt: DateTime(2026, 1, 2)),
      ]);

      // المرة الثانية: u2 يتحدث، u1 يرحل، u3 جديد
      await dao.upsertAll(farm, [
        UserModel(uid: 'u2', name: 'ب-محدث', phone: '9', role: UserRole.manager,
            farmId: farm, createdAt: DateTime(2026, 1, 2)),
        UserModel(uid: 'u3', name: 'ج', phone: '3', role: UserRole.worker,
            farmId: farm, isActive: false, createdAt: DateTime(2026, 1, 3)),
      ]);

      final users = await dao.getByFarm(farm);
      expect(users.map((u) => u.uid).toSet(), {'u2', 'u3'});
      expect(users.firstWhere((u) => u.uid == 'u2').name, 'ب-محدث');
      expect(users.firstWhere((u) => u.uid == 'u2').phone, '9');
      expect(users.firstWhere((u) => u.uid == 'u3').isActive, isFalse);
    });

    test('getByFarm يرجع فارغاً عند عدم وجود كاش', () async {
      expect(await UserDao().getByFarm('farm-x'), isEmpty);
    });
  });

  group('SessionDao - الجلسة', () {
    test('save ثم get ثم hasSession', () async {
      final dao = SessionDao();
      expect(await dao.hasSession(), isFalse);
      await dao.save(userId: 'user-1', farmId: 'farm-1');
      expect(await dao.hasSession(), isTrue);
      final session = await dao.get();
      expect(session?['user_id'], 'user-1');
      expect(session?['farm_id'], 'farm-1');
    });

    test('save يستبدل الجلسة السابقة (سجل واحد)', () async {
      final dao = SessionDao();
      await dao.save(userId: 'user-1', farmId: 'farm-1');
      await dao.save(userId: 'user-2', farmId: 'farm-2');
      final session = await dao.get();
      expect(session?['user_id'], 'user-2');
    });

    test('saveUserJson + getCachedUser يستعيد المستخدم دون إنترنت', () async {
      final dao = SessionDao();
      await dao.save(userId: 'user-1', farmId: 'farm-1');
      await dao.saveUserJson(
          jsonEncode({'uid': 'user-1', 'name': 'محمد', 'role': 'worker'}));

      final session = await dao.get();
      final cached = dao.getCachedUser(session);
      expect(cached?['name'], 'محمد');
      expect(cached?['role'], 'worker');
    });

    test('getCachedUser يعيد null للـ json التالف', () async {
      final dao = SessionDao();
      await dao.save(userId: 'u', farmId: 'f');
      expect(dao.getCachedUser(await dao.get()), isNull);
      await dao.saveUserJson('{not json');
      expect(dao.getCachedUser(await dao.get()), isNull);
    });

    test('clear يمسح الجلسة', () async {
      final dao = SessionDao();
      await dao.save(userId: 'user-1', farmId: 'farm-1');
      await dao.clear();
      expect(await dao.hasSession(), isFalse);
      expect(await dao.get(), isNull);
    });
  });

  group('SettingsDao - مفتاح/قيمة', () {
    test('set يخزن القيمة ويستعيدها ويستبدلها عند التكرار', () async {
      final dao = SettingsDao();
      expect(await dao.get('theme'), isNull);

      await dao.set('theme', 'dark');
      expect(await dao.get('theme'), 'dark');

      await dao.set('theme', 'light');
      expect(await dao.get('theme'), 'light');

      // مفاتيح مستقلة
      await dao.set('language', 'ar');
      expect(await dao.get('theme'), 'light');
      expect(await dao.get('language'), 'ar');
    });
  });

  group('NotesDao - ملاحظات العامل', () {
    test('add نصي ثم getAll بترتيب الأحدث أولاً ثم delete', () async {
      final dao = NotesDao();
      final old = DateTime.now().subtract(const Duration(hours: 2));
      final oldId = await dao.add(content: 'ملاحظة قديمة');
      // محاكاة تقدم الوقت لإظهار الترتيب
      final db = await LocalDatabase.database;
      await db.rawUpdate(
          'UPDATE worker_notes SET created_at = ? WHERE id = ?',
          [old.toIso8601String(), oldId]);

      await dao.add(content: 'ملاحظة جديدة');

      final notes = await dao.getAll();
      expect(notes, hasLength(2));
      expect(notes.first.content, 'ملاحظة جديدة');

      await dao.delete(notes.last.id);
      expect(await dao.getAll(), hasLength(1));
    });

    test('ملاحظة صوتية فقط تُصنَّف isAudioOnly', () async {
      final dao = NotesDao();
      final id = await dao.add(audioPath: '/tmp/note.mp3');
      final all = await dao.getAll();
      expect(all.singleWhere((n) => n.id == id).isAudioOnly, isTrue);
    });
  });

  group('RemindersDao - تذكيرات العامل (محلية فقط)', () {
    test('add ثم getAll بترتيب الأحدث أولاً ثم delete', () async {
      final dao = RemindersDao();
      await dao.add(title: 'تغذية القطيع أ');
      await dao.add(title: 'لقاح', body: 'صباحاً');

      final reminders = await dao.getAll();
      expect(reminders, hasLength(2));
      expect(reminders.map((r) => r.title), ['لقاح', 'تغذية القطيع أ']);
      expect(reminders.first.body, 'صباحاً');

      await dao.delete(reminders.first.id);
      expect(await dao.getAll(), hasLength(1));
    });
  });

  group('OpeningBalanceDao - الأرصدة الافتتاحية', () {
    test('save ثم getForFlock يقرأ الأرصدة ويفك تشفير الأقسام', () async {
      final dao = OpeningBalanceDao();
      final balance = OpeningBalanceModel(
        id: 'ob-1',
        farmId: 'farm-1',
        flockId: 'flock-1',
        createdAt: DateTime(2026, 8, 1),
        initialBirds: 5000,
        eggsProduced: 400,
        eggsDispatched: 380,
        feedConsumedKg: 1200.5,
        mortalityCount: 12,
        totalPayments: 20000,
        totalRevenues: 25000,
        sections: const [
          OpeningSectionModel(sectionNo: 1, initialBirds: 2000, mortalityCount: 5),
          OpeningSectionModel(sectionNo: 2, initialBirds: 3000),
        ],
      );

      await dao.save(balance);

      final loaded = await dao.getForFlock('farm-1', 'flock-1');
      expect(loaded, isNotNull);
      expect(loaded!.initialBirds, 5000);
      expect(loaded.totalRevenues, 25000);
      expect(loaded.sections, hasLength(2));
      expect(loaded.sections[0].sectionNo, 1);
      expect(loaded.sections[0].mortalityCount, 5);
      expect(loaded.sections[1].initialBirds, 3000);
    });

    test('save يسجّل INSERT في طابور المزامنة مع payload نظيف', () async {
      final dao = OpeningBalanceDao();
      await dao.save(OpeningBalanceModel(
        id: 'ob-2',
        farmId: 'farm-1',
        flockId: 'flock-2',
        createdAt: DateTime(2026, 8, 2),
        initialBirds: 100,
      ));

      final rows = await pendingFor('ob-2');
      expect(rows, hasLength(1));
      expect(rows.first['action'], 'INSERT');
      final payload = payloadOf(rows.first);
      expect(payload.containsKey('id'), isFalse);
      expect(payload.containsKey('farm_id'), isFalse);
      expect(payload['flock_id'], 'flock-2');
      // الأقسام تُرفع كنص JSON
      expect(jsonDecode(payload['sections'] as String), isEmpty);
    });

    test('getForFarm يرجع أرصدة المزرعة بترتيب created_at تنازلي', () async {
      final dao = OpeningBalanceDao();
      await dao.save(OpeningBalanceModel(
          id: 'a', farmId: 'farm-1', flockId: 'f1', createdAt: DateTime(2026, 8, 1)));
      await dao.save(OpeningBalanceModel(
          id: 'b', farmId: 'farm-1', flockId: 'f2', createdAt: DateTime(2026, 8, 3)));
      await dao.save(OpeningBalanceModel(
          id: 'c', farmId: 'farm-1', flockId: 'f3', createdAt: DateTime(2026, 8, 2)));

      final all = await dao.getForFarm('farm-1');
      expect(all.map((b) => b.id), ['b', 'c', 'a']);
    });

    test('deleteForFlock يمسح رصيد القطيع', () async {
      final dao = OpeningBalanceDao();
      await dao.save(OpeningBalanceModel(
          id: 'ob-3', farmId: 'farm-1', flockId: 'flock-9',
          createdAt: DateTime(2026, 8, 4)));
      await dao.deleteForFlock('farm-1', 'flock-9');
      expect(await dao.getForFlock('farm-1', 'flock-9'), isNull);
    });
  });

  group('DispatchRequestDao - طلبات التخريج (محلية، بدون مزامنة)', () {
    test('insert ثم getAll/getByFarm بترتيب created_at تنازلي', () async {
      final dao = DispatchRequestDao();
      await dao.insert(DispatchRequestModel(
          farmId: 'farm-1', customerId: 'c1', requestedCartons: 10,
          requestedTrays: 4, notes: 'أول', createdAt: DateTime(2026, 8, 1)));
      await dao.insert(DispatchRequestModel(
          farmId: 'farm-1', customerId: 'c2', requestedCartons: 5,
          requestedTrays: 0, createdAt: DateTime(2026, 8, 3)));

      final all = await dao.getAll();
      expect(all.map((r) => r.status), everyElement('pending'));
      expect(all.map((r) => r.customerId), ['c2', 'c1']);
      expect((await dao.getByFarm('farm-1')), hasLength(2));
      expect(await dao.getByFarm('farm-9'), isEmpty);
    });

    test('insert لا يُولّد سجلات مزامنة', () async {
      final dao = DispatchRequestDao();
      final id = await dao.insert(DispatchRequestModel(
          farmId: 'farm-1', customerId: 'c1', requestedCartons: 1,
          requestedTrays: 0, createdAt: DateTime(2026, 8, 5)));
      expect(await pendingFor(id), isEmpty);
    });

    test('updateStatus ثم delete', () async {
      final dao = DispatchRequestDao();
      final id = await dao.insert(DispatchRequestModel(
          farmId: 'farm-1', customerId: 'c1', requestedCartons: 3,
          requestedTrays: 1, createdAt: DateTime(2026, 8, 6)));

      await dao.updateStatus(id, 'approved');
      final updated = (await dao.getByFarm('farm-1')).single;
      expect(updated.status, 'approved');
      expect(updated.updatedAt, isNotNull);

      await dao.delete(id);
      expect(await dao.getByFarm('farm-1'), isEmpty);
    });
  });

  group('SyncQueueDao - طابور المزامنة', () {
    test('insert يخزن السجلات ثم countByStatus/findByRecordId', () async {
      final dao = SyncQueueDao();
      await dao.insert(
          tableName: 'expenses',
          recordId: 'exp-1',
          action: 'INSERT',
          userId: 'user-1',
          payload: {'amount': 10});
      await dao.insert(
          tableName: 'payments',
          recordId: 'pay-1',
          action: 'INSERT',
          userId: 'user-1',
          payload: {'amount': 20});

      expect(await dao.countByStatus('pending'), 2);
      expect(await dao.countByStatus('synced'), 0);

      final found = await dao.findByRecordId('exp-1');
      expect(found, isNotNull);
      expect(found!['table_name'], 'expenses');
      expect(found['action'], 'INSERT');
      expect(found['user_id'], 'user-1');
      expect(jsonDecode(found['payload'] as String)['amount'], 10);
    });

    test('updateStatus/incrementAttempts/updateError تلاحق حالة السجل', () async {
      final dao = SyncQueueDao();
      await dao.insert(
          tableName: 'flocks',
          recordId: 'fl-1',
          action: 'INSERT',
          userId: 'u',
          payload: {'name': 'x'});

      await dao.incrementAttempts('fl-1');
      await dao.incrementAttempts('fl-1');
      var row = (await dao.findByRecordId('fl-1'))!;
      expect(row['attempts'], 2);

      await dao.updateError('fl-1', 'network down');
      row = (await dao.findByRecordId('fl-1'))!;
      expect(row['status'], 'failed');
      expect(row['last_error'], 'network down');
      expect(await dao.countByStatus('pending'), 0);
      expect(await dao.countByStatus('failed'), 1);

      await dao.updateStatus('fl-1', 'synced');
      expect((await dao.findByRecordId('fl-1'))!['status'], 'synced');
    });

    test('insertError يسجل خطأً عاماً كسجل failed', () async {
      final dao = SyncQueueDao();
      await dao.insertError('boom');
      expect(await dao.countByStatus('failed'), 1);
    });

    test('cleanSynced يحذف السجلات المتزامنة القديمة فقط', () async {
      final dao = SyncQueueDao();
      await dao.insert(
          tableName: 'flocks',
          recordId: 'old',
          action: 'INSERT',
          userId: 'u',
          payload: {});
      await dao.insert(
          tableName: 'flocks',
          recordId: 'new',
          action: 'INSERT',
          userId: 'u',
          payload: {});
      final db = await LocalDatabase.database;
      await db.rawUpdate(
          'UPDATE sync_queue SET status = ?, updated_at = ? WHERE record_id = ?',
          ['synced', DateTime.now().subtract(const Duration(days: 30)).toIso8601String(), 'old']);
      await db.rawUpdate(
          'UPDATE sync_queue SET status = ?, updated_at = ? WHERE record_id = ?',
          [
            'synced',
            DateTime.now().toIso8601String(),
            'new'
          ]);

      await dao.cleanSynced(olderThanDays: 7);

      expect(await dao.findByRecordId('old'), isNull);
      expect(await dao.findByRecordId('new'), isNotNull);
    });
  });
}