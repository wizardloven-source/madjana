import 'dart:convert';
import 'dart:io';

import 'package:data/src/datasources/local/local_database.dart';
import 'package:data/src/repositories/sync_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/db_harness.dart';

/// يُنشئ استجابة JSON ويتصل بها الطلب الأصلي —
/// postgrest يحتاج response.request (Null check) ويجب ربطه يدويًا مع MockClient.
http.Response jsonReply(String body, http.Request request, {int status = 200}) {
  return http.Response(body, status,
      headers: {'content-type': 'application/json'}, request: request);
}

/// بناء SyncRepositoryImpl مع SupabaseClient مُحقون بوهمة HTTP.
SyncRepositoryImpl buildRepo(MockClient client) {
  return SyncRepositoryImpl(
    eggDao: null,
    mortalityDao: null,
    feedDao: null,
    dispatchDao: null,
    medicationDao: null,
    customerDao: null,
    paymentDao: null,
    expenseDao: null,
    syncQueueDao: null,
    remoteEgg: null,
    remoteMortality: null,
    remoteFeed: null,
    remoteDispatch: null,
    remoteMedication: null,
    remotePayment: null,
    supabaseClient: SupabaseClient(
      'http://madjana.test',
      'anon-test-key',
      httpClient: client,
    ),
  );
}

void main() {
  setUpAll(enableFfiDatabase);

  late Directory dbDir;

  setUp(() async {
    dbDir = await createDbHarness('sync_repo');
  });

  tearDown(() => tearDownDbHarness(dbDir));

  Future<List<Map<String, dynamic>>> queueRows() async {
    final db = await LocalDatabase.database;
    return db.query('sync_queue', orderBy: 'created_at ASC');
  }

  group('uploadBatch', () {
    test('صف قديم بلا farm_id: يُسترجع المزرعة من السجل المحلي', () async {
      // This is the failure mode that filed records under the wrong farm: a
      // legacy queue row (pre-v24) with no farm_id used to take the user's
      // active farm from JWT metadata. Now we read the farm from the local
      // record itself, which is the authoritative source.
      // Enqueue through the real API (so NOT NULL columns are satisfied),
      // then clear farm_id to reproduce a legacy pre-v24 row exactly.
      await LocalDatabase.enqueueChange(
        tableName: 'egg_production',
        farmId: 'farm-REAL',
        recordId: 'r-local',
        action: 'INSERT',
        payload: {'flock_id': 'f1', 'cartons': 2},
      );
      final db = await LocalDatabase.database;
      final now = DateTime.now().toIso8601String();
      await db.insert('egg_production', {
        'id': 'r-local',
        'farm_id': 'farm-REAL',
        'flock_id': 'f1',
        'date': '2026-08-20',
        'cartons': 2,
        'worker_id': 'w1',
        'version': 1,
        'created_at': now,
        'updated_at': now,
      });
      await db.rawUpdate(
          'UPDATE sync_queue SET farm_id = NULL, next_retry_at = ?', [now]);

      String? capturedBody;
      final repo = buildRepo(MockClient((request) async {
        capturedBody = request.body;
        return jsonReply(
          jsonEncode({
            'success': true,
            'affected': 1,
            'skipped': 0,
            'errors': 0,
            'success_ids': ['r-local'],
            'failed_ids': <String>[],
            'conflict_ids': <String>[],
            'details': [
              {
                'record_id': 'r-local',
                'table_name': 'egg_production',
                'status': 'ok',
                'new_version': 2,
              }
            ],
          }),
          request,
        );
      }));

      final records = await repo.getPendingChanges();
      expect(records, hasLength(1));
      expect(records.single.farmId, 'farm-REAL');

      // The farm is persisted back into the queue row so the lookup happens
      // once, not on every upload attempt.
      final q = await db.query('sync_queue', where: 'record_id = ?',
          whereArgs: ['r-local']);
      expect(q.single['farm_id'], 'farm-REAL');

      final result = await repo.uploadBatch(records);
      expect(result.successIds, ['r-local']);
      final sent = (jsonDecode(capturedBody!)['records'] as List).first as Map;
      expect(sent['farm_id'], 'farm-REAL');
    });

    test('صف بلا farm_id ولا سجل محلي: يُحجَز ولا يُرفع باسم مزرعة أخرى',
        () async {
      // Queue a row for a record that does not exist locally, then clear its
      // farm_id. The farm cannot be determined from anywhere, so the row must
      // be held back rather than uploaded under some other farm.
      await LocalDatabase.enqueueChange(
        tableName: 'egg_production',
        farmId: 'farm-X',
        recordId: 'r-ghost',
        action: 'INSERT',
        payload: {'flock_id': 'f1'},
      );
      final db = await LocalDatabase.database;
      final now = DateTime.now().toIso8601String();
      await db.rawUpdate(
          'UPDATE sync_queue SET farm_id = NULL, next_retry_at = ?', [now]);

      final repo = buildRepo(MockClient((request) async {
        // fail() returns Never, so no return statement follows: the handler
        // must never produce a response for a row with no known farm.
        fail('يجب ألا يُرفع سجل بلا مزرعة معروفة إطلاقاً');
      }));

      final records = await repo.getPendingChanges();
      expect(records, isEmpty);

      final q = await db.query('sync_queue', where: 'record_id = ?',
          whereArgs: ['r-ghost']);
      expect(q.single['status'], 'pending', reason: 'يبقى معلقاً لا مفقوداً');
      expect(q.single['last_error'], contains('farm_id'));
    });

    test('قائمة فارغة → نتيجة فارغة بدون حجب', () async {
      final repo =
          buildRepo(MockClient((request) async => jsonReply('{}', request)));
      final result = await repo.uploadBatch([]);
      expect(result.successIds, isEmpty);
      expect(result.failedIds, isEmpty);
      expect(result.conflictIds, isEmpty);
    });

    test('نجاح: status=ok → synced + تحديث version محليًا', () async {
      final db = await LocalDatabase.database;
      final now = DateTime.now().toIso8601String();
      // سجلات محلية حقيقية — _updateLocalVersion يحتاجها لتحديث version
      await db.insert('egg_production', {
        'id': 'r1',
        'farm_id': 'farm-1',
        'flock_id': 'f1',
        'date': '2026-08-20',
        'cartons': 2,
        'worker_id': 'w1',
        'version': 1,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('payments', {
        'id': 'p1',
        'farm_id': 'farm-1',
        'customer_id': 'c1',
        'date': '2026-08-20',
        'price_per_carton': 360,
        'total_due': 360,
        'amount_paid': 300,
        'payment_method': 'cash',
        'manager_id': 'm1',
        'version': 2,
        'created_at': now,
        'updated_at': now,
      });
      await LocalDatabase.enqueueChange(
        tableName: 'egg_production',
        farmId: 'farm-1',
        recordId: 'r1',
        action: 'INSERT',
        payload: {'flock_id': 'f1', 'date': '2026-08-20', 'cartons': 2},
      );
      await LocalDatabase.enqueueChange(
        tableName: 'payments',
        farmId: 'farm-1',
        recordId: 'p1',
        action: 'UPDATE',
        previousVersion: 2,
        payload: {'amount_paid': 300},
      );

      String? capturedBody;
      final client = MockClient((request) async {
        capturedBody = request.body;
        return jsonReply(
          jsonEncode({
            'affected': 2,
            'skipped': 0,
            'errors': 0,
            'details': [
              {
                'record_id': 'r1',
                'table_name': 'egg_production',
                'status': 'ok',
                'new_version': 5,
              },
              {
                'record_id': 'p1',
                'table_name': 'payments',
                'status': 'ok',
                'new_version': 9,
              },
            ],
          }),
          request,
        );
      });

      final repo = buildRepo(client);
      final records = await repo.getPendingChanges();
      expect(records, hasLength(2));
      final result = await repo.uploadBatch(records);

      expect(result.successIds, containsAll(['r1', 'p1']));
      expect(result.failedIds, isEmpty);

      // operation_id أُرسل من الطابور، وprevious_version محمول
      final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
      final sent = body['records'] as List;
      expect(sent, hasLength(2));
      final p1 = sent.firstWhere((e) => e['record_id'] == 'p1') as Map;
      expect(p1['previous_version'], 2);
      expect(p1['operation'], 'update');

      // رفع case الحالة في الطابور
      final rows = await queueRows();
      expect(rows.every((r) => r['status'] == 'synced'), isTrue);

      // version محدث محليًا عبر _updateLocalVersion (allowedTables)
      final egg =
          await db.query('egg_production', where: 'id = ?', whereArgs: ['r1']);
      expect(egg.first['version'], 5);
      final pay =
          await db.query('payments', where: 'id = ?', whereArgs: ['p1']);
      expect(pay.first['version'], 9);
    });

    test(
        'عقد Edge Function sync_records: operation صغيرة + previous_version على المستوى الأعلى',
        () async {
      await LocalDatabase.enqueueChange(
        tableName: 'mortality',
        farmId: 'farm-1',
        recordId: 'm1',
        action: 'UPDATE',
        previousVersion: 7,
        payload: {
          'count': 3,
          'id': 'مستبعد',
          'version': 9,
          'farm_id': 'farm-1'
        },
      );

      String? capturedBody;
      final client = MockClient((request) async {
        capturedBody = request.body;
        // نفس صيغة الرد الحقيقية من Edge Function (مع success_ids/failed_ids/conflict_ids)
        return jsonReply(
          jsonEncode({
            'success': true,
            'affected': 1,
            'skipped': 0,
            'errors': 0,
            'success_ids': ['m1'],
            'failed_ids': <String>[],
            'conflict_ids': <String>[],
            'details': [
              {
                'record_id': 'm1',
                'table_name': 'mortality',
                'status': 'ok',
                'new_version': 8,
              },
            ],
          }),
          request,
        );
      });

      final repo = buildRepo(client);
      final records = await repo.getPendingChanges();
      final result = await repo.uploadBatch(records);
      expect(result.successIds, ['m1']);

      // validateRecord في الـ Edge يقبل 'insert'/'update'/'delete' الصغيرة فقط —
      // أي تغيير مستقبلي لحالة enum يكسر المصادقة بصمت.
      final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
      final sent = (body['records'] as List).first as Map;
      expect(sent['operation'], 'update');

      // previous_version يُقرأ أعلى المستوى (يصله null في INSERT)
      expect(sent['previous_version'], 7);

      // data = payload نظيف: بلا id/version — وprevious_version داخله جزء من عقد OCC
      final data = sent['data'] as Map;
      expect(data.containsKey('previous_version'), isTrue);
      expect(data['previous_version'], 7);
      expect(data['count'], 3);
      expect(data.containsKey('id'), isFalse);
      expect(data.containsKey('version'), isFalse);

      // farm_id الآن داخل data عمداً، وعلى مستوى السجل أيضاً. قبل هذا التغيير
      // كانت data خالية منه، فيقرأه الخادم من الصومعة فينقص أي أثر في
      // linkage — أو يسقط إلى المزرعة النشطة فتُسجَّل الدفعة في مزرعة خاطئة.
      expect(data['farm_id'], 'farm-1');
      expect(sent['farm_id'], 'farm-1');
    });

    test('conflict: status=conflict → يحوَّل إلى حالة conflict', () async {
      await LocalDatabase.enqueueChange(
        tableName: 'egg_production',
        farmId: 'farm-1',
        recordId: 'r1',
        action: 'UPDATE',
        previousVersion: 1,
        payload: {'cartons': 3},
      );

      final client = MockClient((request) async => jsonReply(
          jsonEncode({
            'affected': 0,
            'skipped': 0,
            'errors': 0,
            'details': [
              {
                'record_id': 'r1',
                'table_name': 'egg_production',
                'status': 'conflict',
              },
            ],
          }),
          request));

      final repo = buildRepo(client);
      final records = await repo.getPendingChanges();
      final result = await repo.uploadBatch(records);

      expect(result.conflictIds, ['r1']);
      expect(result.failedIds, isEmpty);
      final rows = await queueRows();
      expect(rows.first['status'], 'conflict');
    });

    test('skipped → يبقى pending (الخادم لم يطبّع، فالعملية لم تُنفَّذ)',
        () async {
      await LocalDatabase.enqueueChange(
        tableName: 'mortality',
        farmId: 'farm-1',
        recordId: 'm1',
        action: 'INSERT',
        payload: {'count': 3},
      );

      final client = MockClient((request) async => jsonReply(
          jsonEncode({
            'affected': 0,
            'skipped': 1,
            'errors': 0,
            'details': [
              {
                'record_id': 'm1',
                'table_name': 'mortality',
                'status': 'skipped',
              },
            ],
          }),
          request));

      final repo = buildRepo(client);
      final records = await repo.getPendingChanges();
      final result = await repo.uploadBatch(records);

      // «skipped» تعني أن الخادم لم يطبّق العملية (السجل غير موجود أو
      // لا ينتمي للمزرعة). اعتبارها نجاحاً يحذفها من الطابور نهائياً =
      // فقدان تعديل محلي. تبقى pending مع رسالة صريحة.
      expect(result.successIds, isEmpty);
      expect(result.failedIds, isEmpty);
      final rows = await queueRows();
      expect(rows.first['status'], 'pending');
      expect(rows.first['last_error_code'], 'SKIPPED_NOT_FOUND');
      expect(rows.first['last_error'], isNotNull);
    });

    test('سجل مرفوض (لا يوجد detail له) → يعامل كفشل', () async {
      await LocalDatabase.enqueueChange(
        tableName: 'egg_production',
        farmId: 'farm-1',
        recordId: 'r1',
        action: 'INSERT',
        payload: {'flock_id': 'f1'},
      );
      await LocalDatabase.enqueueChange(
        tableName: 'egg_production',
        farmId: 'farm-1',
        recordId: 'r2',
        action: 'INSERT',
        payload: {'flock_id': 'f2'},
      );

      // Edge Function يرفض r2 (لا يظهر في details بتاتًا)
      final client = MockClient((request) async => jsonReply(
          jsonEncode({
            'affected': 1,
            'skipped': 0,
            'errors': 0,
            'details': [
              {
                'record_id': 'r1',
                'table_name': 'egg_production',
                'status': 'ok',
                'new_version': 2,
              },
            ],
          }),
          request));

      final repo = buildRepo(client);
      final records = await repo.getPendingChanges();
      expect(records, hasLength(2));
      final result = await repo.uploadBatch(records);

      expect(result.successIds, ['r1']);
      expect(result.failedIds, ['r2']);

      final rows = await queueRows();
      final byId = {for (final r in rows) r['record_id'] as String: r};
      expect(byId['r1']!['status'], 'synced');
      expect(byId['r2']!['status'], 'failed');
    });

    test('فشل شبكة → يبقى pending مع attempts و backoff حتى فشل نهائي',
        () async {
      await LocalDatabase.enqueueChange(
        tableName: 'egg_production',
        farmId: 'farm-1',
        recordId: 'r1',
        action: 'INSERT',
        payload: {'flock_id': 'f1'},
      );

      final failingClient = MockClient((request) async =>
          jsonReply('{"error":"boom"}', request, status: 500));

      final repo = buildRepo(failingClient);
      final db = await LocalDatabase.database;

      for (var i = 0; i < 4; i++) {
        final records = await repo.getPendingChanges();
        final result = await repo.uploadBatch(records);
        expect(result.failedIds, ['r1']);
        // يحاكي مرور وقت إعادة المحاولة (next_retry_at انقضى)
        await db.rawUpdate('UPDATE sync_queue SET next_retry_at = NULL');
      }

      // بعد أول فشل: pending + attempts=1 + next_retry_at في المستقبل القريب
      var row = (await queueRows()).first;
      expect(row['status'], 'pending');
      expect(row['attempts'], 4);
      expect(row['last_error_code'], 'RETRYABLE');

      // المحاولة الخامسة تتجاوز الحد → failed
      final records5 = await repo.getPendingChanges();
      final last = await repo.uploadBatch(records5);
      expect(last.failedIds, ['r1']);

      row = (await queueRows()).first;
      expect(row['status'], 'failed');
      expect(row['attempts'], 5);
    });
  });

  group('pullAndMerge', () {
    test('لا تغييرات → PullResult فارغ و sync_state بدون تغيير', () async {
      final client = MockClient((request) async => jsonReply(
          jsonEncode(
              {'latest_version': 0, 'resync_required': false, 'changes': []}),
          request));
      final repo = buildRepo(client);
      final result = await repo.pullAndMerge('farm-1');
      expect(result.appliedCount, 0);
      expect(result.latestVersion, 0);

      final db = await LocalDatabase.database;
      final state = await db.query('sync_state');
      expect(state, isEmpty);
    });

    test('resync_required → يُعلم المتصل دون تقدم مؤشر السحب', () async {
      final client = MockClient((request) async => jsonReply(
          jsonEncode({
            'latest_version': 50,
            'resync_required': true,
            'changes': [],
          }),
          request));
      final repo = buildRepo(client);
      final result = await repo.pullAndMerge('farm-1');
      expect(result.resyncRequired, isTrue);
      expect(result.latestVersion, 50);

      final db = await LocalDatabase.database;
      expect(await db.query('sync_state'), isEmpty);
    });

    test('دمج INSERT/UPDATE مع فلترة الأعمدة + تقدّم commit-point', () async {
      final client = MockClient((request) async => jsonReply(
          jsonEncode({
            'latest_version': 3,
            'resync_required': false,
            'changes': [
              {
                'table_name': 'egg_production',
                'record_id': 'r1',
                'operation': 'INSERT',
                'server_version': 1,
                'payload': {
                  'farm_id': 'farm-1',
                  'flock_id': 'f1',
                  'date': '2026-08-20',
                  'cartons': 2,
                  'trays': 1,
                  'loose_eggs': 5,
                  'worker_id': 'w1',
                  'version': 1,
                  'عمود_غير_موجود': 'يُفلتر',
                },
              },
              {
                'table_name': 'payments',
                'record_id': 'p1',
                'operation': 'UPDATE',
                'server_version': 3,
                'payload': {
                  'farm_id': 'farm-1',
                  'customer_id': 'c1',
                  'date': '2026-08-20',
                  'price_per_carton': 360,
                  'total_due': 720,
                  'amount_paid': 200,
                  'payment_method': 'cash',
                  'manager_id': 'm1',
                  'version': 1,
                },
              },
            ],
          }),
          request));
      final repo = buildRepo(client);
      final result = await repo.pullAndMerge('farm-1');

      expect(result.downloadedCount, 2);
      expect(result.appliedCount, 2);
      expect(result.conflictCount, 0);
      expect(result.latestVersion, 3);

      final db = await LocalDatabase.database;
      final egg =
          await db.query('egg_production', where: 'id = ?', whereArgs: ['r1']);
      expect(egg, hasLength(1));
      expect(egg.first['cartons'], 2);

      final pay =
          await db.query('payments', where: 'id = ?', whereArgs: ['p1']);
      expect(pay, hasLength(1));
      expect(pay.first['amount_paid'], 200);

      final state =
          await db.query('sync_state', where: 'id = ?', whereArgs: ['farm-1']);
      expect(state.first['last_pulled_version'], 3);
    });

    test('جدول غير محلي في المنتصف → يُتخطى ويُدفع commit-point فوقه',
        () async {
      final client = MockClient((request) async => jsonReply(
          jsonEncode({
            'latest_version': 3,
            'resync_required': false,
            'changes': [
              {
                'table_name': 'egg_production',
                'record_id': 'r1',
                'operation': 'INSERT',
                'server_version': 1,
                'payload': {
                  'farm_id': 'farm-1',
                  'flock_id': 'f1',
                  'date': '2026-08-20',
                  'cartons': 1,
                  'trays': 0,
                  'loose_eggs': 0,
                  'worker_id': 'w1',
                },
              },
              {
                // جدول غير محلي (مثل app_notifications) — يُتخطى عمداً
                // ويُدفع commit-point فوقه كي لا يُعلّق وصول الإصدارات الأحدث
                'table_name': 'table_bad',
                'record_id': 'x1',
                'operation': 'DELETE',
                'server_version': 2,
                'payload': {},
              },
              {
                'table_name': 'egg_production',
                'record_id': 'r2',
                'operation': 'INSERT',
                'server_version': 3,
                'payload': {
                  'farm_id': 'farm-1',
                  'flock_id': 'f1',
                  'date': '2026-08-21',
                  'cartons': 7,
                  'trays': 0,
                  'loose_eggs': 0,
                  'worker_id': 'w1',
                },
              },
            ],
          }),
          request));
      final repo = buildRepo(client);
      final result = await repo.pullAndMerge('farm-1');

      expect(result.downloadedCount, 3);
      expect(result.appliedCount, 2);
      expect(result.conflictCount, 0);

      final db = await LocalDatabase.database;
      // r1 و r2 طُبقا (الجدول غير المحلي أُسقط دون اعتباره فشلاً)
      expect(
          await db.query('egg_production', where: 'id = ?', whereArgs: ['r1']),
          hasLength(1));
      expect(
          await db.query('egg_production', where: 'id = ?', whereArgs: ['r2']),
          hasLength(1));
      // watermark تجاوز الصف المُتخطّى ووصل لآخر نسخة متعاقبة ناجحة
      final state =
          await db.query('sync_state', where: 'id = ?', whereArgs: ['farm-1']);
      expect(state.first['last_pulled_version'], 3);
    });
  });

  group('syncNow (دورة كاملة)', () {
    test('رفع ناجح + سحب ناجح و تسجيل في sync_history', () async {
      await LocalDatabase.enqueueChange(
        tableName: 'egg_production',
        farmId: 'farm-1',
        recordId: 'r1',
        action: 'INSERT',
        payload: {'flock_id': 'f1', 'date': '2026-08-20', 'cartons': 4},
      );

      final client = MockClient((request) async {
        if (request.url.path.endsWith('/functions/v1/sync_records')) {
          return jsonReply(
              jsonEncode({
                'affected': 1,
                'skipped': 0,
                'errors': 0,
                'details': [
                  {
                    'record_id': 'r1',
                    'table_name': 'egg_production',
                    'status': 'ok',
                    'new_version': 5,
                  },
                ],
              }),
              request);
        }
        if (request.url.path.endsWith('/rest/v1/rpc/pull_remote_changes')) {
          return jsonReply(
              jsonEncode({
                'latest_version': 11,
                'resync_required': false,
                'changes': [
                  {
                    'table_name': 'egg_dispatch',
                    'record_id': 'd1',
                    'operation': 'INSERT',
                    'server_version': 11,
                    'payload': {
                      'farm_id': 'farm-1',
                      'customer_id': 'c1',
                      'date': '2026-08-20',
                      'cartons': 10,
                      'trays': 0,
                      'total_eggs': 3600,
                      'worker_id': 'w1',
                    },
                  },
                ],
              }),
              request);
        }
        return jsonReply('{"error":"unexpected"}', request, status: 404);
      });

      final repo = buildRepo(client);
      final result = await repo.syncNow('farm-1');

      expect(result.uploadedCount, 1);
      expect(result.downloadedCount, 1);
      expect(result.failedCount, 0);
      expect(result.resyncRequired, isFalse);

      final db = await LocalDatabase.database;
      expect(await db.query('egg_dispatch', where: 'id = ?', whereArgs: ['d1']),
          hasLength(1));

      final history = await db.query('sync_history');
      expect(history, hasLength(1));
      expect(history.first['uploaded'], 1);
      expect(history.first['downloaded'], 1);
    });
  });
}
