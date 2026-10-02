import 'dart:convert';
import 'dart:io';

import 'package:core/core.dart';
import 'package:data/data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/db_harness.dart';
import 'support/fake_supabase_api.dart';

const _farmId = 'farm-1';
const _flockId = 'flock-1';
const _workerId = 'worker-1';

/// خادم مذياع الحالة يحاكي عقد المزامنة الحقيقي:
/// - `sync_records`: يطبّق upsert/delete ويشعّ إصدارًا جديدًا لكل سجل.
/// - `pull_remote_changes`: يُرجع تغييرات المزرعة بعد watermark.
/// - `sync_live_ids`: بلا سجلات ⇒ لا مصالحة حذف.
/// ويحاكي التريجر `trg_calc_total_eggs` بحساب total_eggs لبند البيض،
/// وpopulate_sync_changes بحذف sync_status/deleted_at من الحمولة.
class _FakeSyncServer {
  final Map<String, Map<String, Map<String, dynamic>>> tables = {};
  final List<Map<String, dynamic>> changes = [];
  int _version = 0;

  MockClient client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/functions/v1/sync_records')) {
      return _reply(jsonEncode(_applyUpload(request)), request);
    }
    if (path.endsWith('/rest/v1/rpc/pull_remote_changes')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final farmId = body['p_farm_id'] as String;
      final from = (body['p_from_version'] as num?)?.toInt() ?? 0;
      final visible = changes
          .where((c) =>
              c['farm_id'] == farmId && (c['server_version'] as int) > from)
          .toList();
      return _reply(
        jsonEncode({
          'latest_version': _version,
          'resync_required': false,
          'changes': visible,
        }),
        request,
      );
    }
    if (path.endsWith('/rest/v1/rpc/sync_live_ids')) {
      return _reply(jsonEncode(<String, dynamic>{}), request);
    }
    return _reply('{"error":"unexpected ${request.url}"}', request, status: 404);
  }

  http.Response _reply(String body, http.Request request, {int status = 200}) {
    return http.Response(body, status,
        headers: {'content-type': 'application/json'}, request: request);
  }

  Map<String, dynamic> _applyUpload(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final records = (body['records'] as List).cast<Map<String, dynamic>>();
    final details = <Map<String, dynamic>>[];
    final successIds = <String>[];

    for (final r in records) {
      final table = r['table_name'] as String;
      final recordId = r['record_id'] as String;
      final operation = (r['operation'] as String).toUpperCase();
      final operationId = r['operation_id'] as String?;
      final farmId = (r['farm_id'] as String?) ??
          ((r['data'] as Map?)?['farm_id'] as String?);

      final data = Map<String, dynamic>.from(
          (r['data'] as Map?) ?? const <String, dynamic>{});
      data.remove('previous_version');
      data['id'] = recordId;
      if (farmId != null) data['farm_id'] = farmId;

      _version++;
      final rows = tables.putIfAbsent(table, () => {});
      if (operation == 'DELETE') {
        rows.remove(recordId);
      } else {
        final merged = <String, dynamic>{
          if (rows[recordId] != null) ...rows[recordId]!,
          ...data,
        };
        if (table == 'egg_production') {
          merged['total_eggs'] = (merged['cartons'] as int? ?? 0) * 360 +
              (merged['trays'] as int? ?? 0) * 30 +
              (merged['loose_eggs'] as int? ?? 0);
        }
        merged['version'] = _version;
        rows[recordId] = merged;
      }

      changes.add({
        'table_name': table,
        'record_id': recordId,
        'operation': operation,
        'server_version': _version,
        'farm_id': farmId,
        'payload': Map<String, dynamic>.from(rows[recordId] ?? data),
      });

      details.add({
        'record_id': recordId,
        'table_name': table,
        'status': 'ok',
        'new_version': _version,
        if (operationId != null) 'operation_id': operationId,
      });
      successIds.add(recordId);
    }

    return {
      'success': true,
      'affected': successIds.length,
      'skipped': 0,
      'errors': 0,
      'success_ids': successIds,
      'failed_ids': <String>[],
      'conflict_ids': <String>[],
      'details': details,
    };
  }
}

SyncRepositoryImpl buildSyncRepo(MockClient client) {
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

EggProductionRepositoryImpl eggRepo() => EggProductionRepositoryImpl(
      localDao: EggProductionDao(),
      remoteDatasource: SupabaseEggDatasource(FakeSupabaseApi()),
    );

MortalityRepositoryImpl mortalityRepo() => MortalityRepositoryImpl(
      localDao: MortalityDao(),
      remoteDatasource: SupabaseMortalityDatasource(FakeSupabaseApi()),
    );

FeedRepositoryImpl feedRepo() => FeedRepositoryImpl(
      localDao: FeedDao(),
      remoteDatasource: SupabaseFeedDatasource(FakeSupabaseApi()),
    );

void main() {
  setUpAll(enableFfiDatabase);

  late _FakeSyncServer server;
  final dirs = <Directory>[];

  setUp(() {
    server = _FakeSyncServer();
    dirs.clear();
  });

  tearDown(() async {
    for (final d in dirs) {
      await tearDownDbHarness(d);
    }
  });

  Future<Database> device(String label) async {
    final dir = await createDbHarness(label);
    dirs.add(dir);
    return LocalDatabase.database;
  }

  final date = DateTime.now().subtract(const Duration(days: 1));

  test('إنتاج البيض: إدخال → حفظ محلي → مزامنة → ظهور على جهاز ثانٍ',
      () async {
    final dbA = await device('egg_a');

    final save = await SaveEggProductionUseCase(eggRepo()).call(
      EggProductionModel(
        farmId: _farmId,
        flockId: _flockId,
        date: date,
        cartons: 2,
        trays: 1,
        looseEggs: 5,
        workerId: _workerId,
        sectionNo: 1,
      ),
    );
    expect(save.success, isTrue, reason: save.error);

    final local = await dbA.query('egg_production');
    expect(local, hasLength(1));
    expect(local.first['sync_status'], 'pending');
    expect(local.first['total_eggs'], 755);
    final id = local.first['id'] as String;

    final queued = await dbA
        .query('sync_queue', where: 'record_id = ?', whereArgs: [id]);
    expect(queued, hasLength(1));
    expect(queued.first['table_name'], 'egg_production');
    expect(queued.first['action'], 'INSERT');
    expect(queued.first['farm_id'], _farmId);

    final syncA = await buildSyncRepo(server.client()).syncNow(_farmId);
    expect(syncA.uploadedCount, 1);
    expect(syncA.failedCount, 0);
    expect(server.tables['egg_production']![id]!['cartons'], 2);
    expect(server.tables['egg_production']![id]!['total_eggs'], 755);

    final queuedAfter = await dbA
        .query('sync_queue', where: 'record_id = ?', whereArgs: [id]);
    expect(queuedAfter.first['status'], 'synced');

    final dbB = await device('egg_b');
    final syncB = await buildSyncRepo(server.client()).syncNow(_farmId);
    expect(syncB.downloadedCount, greaterThanOrEqualTo(1));

    final pulled =
        await dbB.query('egg_production', where: 'id = ?', whereArgs: [id]);
    expect(pulled, hasLength(1));
    expect(pulled.first['farm_id'], _farmId);
    expect(pulled.first['flock_id'], _flockId);
    expect(pulled.first['cartons'], 2);
    expect(pulled.first['trays'], 1);
    expect(pulled.first['loose_eggs'], 5);
    expect(pulled.first['total_eggs'], 755);
  });

  test('النفوق: إدخال → حفظ محلي → مزامنة → ظهور على جهاز ثانٍ', () async {
    final dbA = await device('mortality_a');
    await dbA.insert('flocks', {
      'id': _flockId,
      'farm_id': _farmId,
      'breed': 'layer',
      'start_date': '2026-01-01',
      'initial_count': 1000,
      'current_count': 990,
    });

    final save = await SaveMortalityUseCase(mortalityRepo()).call(
      MortalityModel(
        farmId: _farmId,
        flockId: _flockId,
        date: date,
        count: 4,
        reason: MortalityReason.notEating,
        notes: 'عينة',
        workerId: _workerId,
        sectionNo: 1,
      ),
    );
    expect(save.success, isTrue, reason: save.error);

    final local = await dbA.query('mortality');
    expect(local, hasLength(1));
    expect(local.first['reason'], 'not_eating');
    expect(local.first['count'], 4);
    final id = local.first['id'] as String;

    final queued = await dbA
        .query('sync_queue', where: 'record_id = ?', whereArgs: [id]);
    expect(queued, hasLength(1));
    expect(queued.first['table_name'], 'mortality');
    expect(queued.first['farm_id'], _farmId);

    final syncA = await buildSyncRepo(server.client()).syncNow(_farmId);
    expect(syncA.uploadedCount, 1);
    expect(server.tables['mortality']![id]!['count'], 4);

    final dbB = await device('mortality_b');
    final syncB = await buildSyncRepo(server.client()).syncNow(_farmId);
    expect(syncB.downloadedCount, greaterThanOrEqualTo(1));

    final pulled =
        await dbB.query('mortality', where: 'id = ?', whereArgs: [id]);
    expect(pulled, hasLength(1));
    expect(pulled.first['flock_id'], _flockId);
    expect(pulled.first['count'], 4);
    expect(pulled.first['reason'], 'not_eating');
    expect(pulled.first['notes'], 'عينة');
  });

  test('استهلاك العلف: إدخال → حفظ محلي → مزامنة → ظهور على جهاز ثانٍ',
      () async {
    final dbA = await device('feed_consumption_a');

    final save = await SaveFeedConsumptionUseCase(feedRepo()).call(
      FeedConsumptionModel.fromBags(
        farmId: _farmId,
        date: date,
        bags: 3,
        workerId: _workerId,
      ),
    );
    expect(save.success, isTrue, reason: save.error);

    final local = await dbA.query('feed_consumption');
    expect(local, hasLength(1));
    expect(local.first['entry_mode'], 'bags');
    expect(local.first['bags_count'], 3);
    expect(local.first['quantity_kg'], 150.0);
    final id = local.first['id'] as String;

    final queued = await dbA
        .query('sync_queue', where: 'record_id = ?', whereArgs: [id]);
    expect(queued, hasLength(1));
    expect(queued.first['table_name'], 'feed_consumption');
    expect(queued.first['farm_id'], _farmId);

    final syncA = await buildSyncRepo(server.client()).syncNow(_farmId);
    expect(syncA.uploadedCount, 1);
    expect(server.tables['feed_consumption']![id]!['quantity_kg'], 150.0);

    final dbB = await device('feed_consumption_b');
    final syncB = await buildSyncRepo(server.client()).syncNow(_farmId);
    expect(syncB.downloadedCount, greaterThanOrEqualTo(1));

    final pulled =
        await dbB.query('feed_consumption', where: 'id = ?', whereArgs: [id]);
    expect(pulled, hasLength(1));
    expect(pulled.first['entry_mode'], 'bags');
    expect(pulled.first['bags_count'], 3);
    expect(pulled.first['quantity_kg'], 150.0);
  });

  test('استلام العلف: إدخال → حفظ محلي → مزامنة → ظهور على جهاز ثانٍ',
      () async {
    final dbA = await device('feed_received_a');

    await feedRepo().saveReceivedLocal(
      FeedReceivedModel(
        farmId: _farmId,
        date: date,
        entryMode: FeedEntryMode.bags,
        quantity: 10,
        quantityKg: 500,
        feedType: FeedType.main,
        supplier: 'المورد',
        invoiceNumber: 'INV-1',
        notes: 'شحنة',
        workerId: _workerId,
      ),
    );

    final local = await dbA.query('feed_received');
    expect(local, hasLength(1));
    expect(local.first['quantity_kg'], 500.0);
    expect(local.first['feed_type'], 'main');
    expect(local.first['supplier'], 'المورد');
    final id = local.first['id'] as String;

    final queued = await dbA
        .query('sync_queue', where: 'record_id = ?', whereArgs: [id]);
    expect(queued, hasLength(1));
    expect(queued.first['table_name'], 'feed_received');
    expect(queued.first['farm_id'], _farmId);

    final syncA = await buildSyncRepo(server.client()).syncNow(_farmId);
    expect(syncA.uploadedCount, 1);
    expect(server.tables['feed_received']![id]!['quantity_kg'], 500.0);

    final dbB = await device('feed_received_b');
    final syncB = await buildSyncRepo(server.client()).syncNow(_farmId);
    expect(syncB.downloadedCount, greaterThanOrEqualTo(1));

    final pulled =
        await dbB.query('feed_received', where: 'id = ?', whereArgs: [id]);
    expect(pulled, hasLength(1));
    expect(pulled.first['quantity_kg'], 500.0);
    expect(pulled.first['feed_type'], 'main');
    expect(pulled.first['supplier'], 'المورد');
    expect(pulled.first['invoice_number'], 'INV-1');
  });
}
