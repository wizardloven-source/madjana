import 'package:core/core.dart';
import 'package:domain/domain.dart';
import 'package:sqflite/sqflite.dart';
import '../datasources/local/daos/customer_dao.dart';
import '../datasources/local/daos/dispatch_dao.dart';
import '../datasources/local/daos/egg_production_dao.dart';
import '../datasources/local/daos/feed_dao.dart';
import '../datasources/local/daos/medication_dao.dart';
import '../datasources/local/daos/mortality_dao.dart';
import '../datasources/local/daos/sync_queue_dao.dart';
import '../datasources/local/local_database.dart';
import '../datasources/remote/supabase_dispatch_datasource.dart';
import '../datasources/remote/supabase_egg_datasource.dart';
import '../datasources/remote/supabase_feed_datasource.dart';
import '../datasources/remote/supabase_medication_datasource.dart';
import '../datasources/remote/supabase_mortality_datasource.dart';
import '../datasources/remote/supabase_payment_datasource.dart';

/// تنفيذ مستودع المزامنة
///
/// يجمع السجلات المعلقة من كل الجداول ويرفعها بالدفعات.
/// حل التعارض: السجل الأحدث يفوز (Last Write Wins).
class SyncRepositoryImpl implements SyncRepository {
  final EggProductionDao _eggDao;
  final MortalityDao _mortalityDao;
  final FeedDao _feedDao;
  final DispatchDao _dispatchDao;
  final MedicationDao _medicationDao;
  final CustomerDao _customerDao;
  final SyncQueueDao _syncQueueDao;

  final SupabaseEggDatasource _remoteEgg;
  final SupabaseMortalityDatasource _remoteMortality;
  final SupabaseFeedDatasource _remoteFeed;
  final SupabaseDispatchDatasource _remoteDispatch;
  final SupabaseMedicationDatasource _remoteMedication;
  final SupabasePaymentDatasource _remotePayment;

  SyncRepositoryImpl({
    required EggProductionDao eggDao,
    required MortalityDao mortalityDao,
    required FeedDao feedDao,
    required DispatchDao dispatchDao,
    required MedicationDao medicationDao,
    required CustomerDao customerDao,
    required SyncQueueDao syncQueueDao,
    required SupabaseEggDatasource remoteEgg,
    required SupabaseMortalityDatasource remoteMortality,
    required SupabaseFeedDatasource remoteFeed,
    required SupabaseDispatchDatasource remoteDispatch,
    required SupabaseMedicationDatasource remoteMedication,
    required SupabasePaymentDatasource remotePayment,
  })  : _eggDao = eggDao,
        _mortalityDao = mortalityDao,
        _feedDao = feedDao,
        _dispatchDao = dispatchDao,
        _medicationDao = medicationDao,
        _customerDao = customerDao,
        _syncQueueDao = syncQueueDao,
        _remoteEgg = remoteEgg,
        _remoteMortality = remoteMortality,
        _remoteFeed = remoteFeed,
        _remoteDispatch = remoteDispatch,
        _remoteMedication = remoteMedication,
        _remotePayment = remotePayment;

  @override
  Future<List<SyncRecord>> getPendingRecords({int limit = 50}) async {
    final records = <SyncRecord>[];

    final eggs = await _eggDao.getPendingRecords(limit: limit);
    for (final e in eggs) {
      records.add(SyncRecord(
        id: e.id,
        tableName: 'egg_production',
        recordId: e.id!,
        payload: e.toJson(),
        updatedAt: e.updatedAt ?? e.createdAt ?? DateTime.now(),
      ));
    }

    final mortality = await _mortalityDao.getPendingRecords(limit: limit);
    for (final m in mortality) {
      records.add(SyncRecord(
        id: m.id,
        tableName: 'mortality',
        recordId: m.id!,
        payload: m.toJson(),
        updatedAt: m.date,
      ));
    }

    final consumption = await _feedDao.getPendingConsumption(limit: limit);
    for (final c in consumption) {
      records.add(SyncRecord(
        id: c.id,
        tableName: 'feed_consumption',
        recordId: c.id!,
        payload: c.toJson(),
        updatedAt: c.date,
      ));
    }

    final received = await _feedDao.getPendingReceived(limit: limit);
    for (final r in received) {
      records.add(SyncRecord(
        id: r.id,
        tableName: 'feed_received',
        recordId: r.id!,
        payload: r.toJson(),
        updatedAt: r.date,
      ));
    }

    final dispatches = await _dispatchDao.getPendingRecords(limit: limit);
    for (final d in dispatches) {
      records.add(SyncRecord(
        id: d.id,
        tableName: 'egg_dispatch',
        recordId: d.id!,
        payload: d.toJson(),
        updatedAt: d.date,
      ));
    }

    final medications = await _medicationDao.getPendingRecords(limit: limit);
    for (final m in medications) {
      records.add(SyncRecord(
        id: m.id,
        tableName: 'medications',
        recordId: m.id!,
        payload: m.toJson(),
        updatedAt: m.date,
      ));
    }

    // زبائن لم تُرفع بعد
    final customers = await _customerDao.getPendingRecords(limit: limit);
    for (final c in customers) {
      records.add(SyncRecord(
        id: c.id,
        tableName: 'customers',
        recordId: c.id!,
        payload: c.toJson(),
        updatedAt: DateTime.now(),
      ));
    }

    // كل جدول محدود بـ limit داخلياً، دون قصّ إجمالي قد يحذف الزبائن
    // (الزبائن تُضاف أخيراً وكانت تُقصّ عند تجاوز الحد الأجمالي)
    return records;
  }

  /// الجداول التشغيلية التي تُسحب من السحابة إلى الجهاز
  static const List<String> _pullTables = [
    'egg_production',
    'mortality',
    'feed_consumption',
    'feed_received',
    'egg_dispatch',
    'medications',
    'customers',
    'expenses',
    'payments',
    'flocks',
    'users',
  ];

  @override
  Future<int> pullRemoteRecords(String farmId) async {
    final db = await LocalDatabase.database;
    var pulled = 0;

    for (final table in _pullTables) {
      try {
        final rows = await _remoteEgg.client
            .from(table)
            .select()
            .eq('farm_id', farmId);

        // أعمدة الجدول المحلي — لتجاهل أي مفاتيح غير موجودة محلياً
        final columns = <String>{};
        final info = await db.rawQuery('PRAGMA table_info($table)');
        for (final col in info) {
          columns.add(col['name'] as String);
        }
        final hasSyncStatus = columns.contains('sync_status');

        for (final raw in rows as List) {
          try {
            final row = Map<String, dynamic>.from(raw as Map);
            final id = row['id'] as String?;
            if (id == null) continue;

            // لا نطغى على سجلات محلية لم تُزامَن بعد
            if (hasSyncStatus) {
              final existing = await db.query(
                table,
                where: 'id = ?',
                whereArgs: [id],
                limit: 1,
              );
              if (existing.isNotEmpty &&
                  existing.first['sync_status'] == SyncStatus.pending.name) {
                continue;
              }
              row['sync_status'] = SyncStatus.synced.name;
            }

            row.removeWhere((k, _) => !columns.contains(k));

            if (!row.containsKey('created_at') ||
                row['created_at'] == null) {
              row['created_at'] = DateTime.now().toIso8601String();
            }

            await db.insert(
              table,
              row,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            pulled++;
          } catch (_) {
            // تخطَّ الصف التالف
          }
        }
      } catch (_) {
        // جدول غير موجود أو لا اتصال — تجاهل وانتقل للتالي
      }
    }

    return pulled;
  }

  @override
  Future<int> syncNow(String farmId) async {
    final records = await getPendingRecords();
    if (records.isNotEmpty) {
      final result = await uploadBatch(records);
      for (final record in records) {
        if (record.id == null) continue;
        if (result.successIds.contains(record.id)) {
          await markAsSynced(record.id!);
        } else {
          await incrementAttempts(record.id!);
        }
      }
    }
    return await pullRemoteRecords(farmId);
  }

  @override
  Future<int> getPendingCount() async {
    var count = await _eggDao.countPending();
    count += await _mortalityDao.countPending();
    count += await _feedDao.countPendingConsumption();
    count += await _feedDao.countPendingReceived();
    count += await _dispatchDao.countPending();
    count += await _medicationDao.countPending();
    count += await _customerDao.countPending();
    return count;
  }

  @override
  Future<int> getSyncedCount() async => await _syncQueueDao.countByStatus('synced');

  @override
  Future<int> getFailedCount() async => await _syncQueueDao.countByStatus('failed');

  @override
  Future<BatchUploadResult> uploadBatch(List<SyncRecord> records) async {
    final successIds = <String>[];
    final failedIds = <String>[];

    // بيض
    final eggs = records.where((r) => r.tableName == 'egg_production').toList();
    if (eggs.isNotEmpty) {
      final models = eggs.map((r) => EggProductionModel.fromJson(r.payload)).toList();
      final result = await _remoteEgg.insertBatch(models);
      successIds.addAll(result.successIds);
      failedIds.addAll(result.failedIds);
    }

    // نفوق
    final mortalities =
        records.where((r) => r.tableName == 'mortality').toList();
    if (mortalities.isNotEmpty) {
      final models =
          mortalities.map((r) => MortalityModel.fromJson(r.payload)).toList();
      final mResult = await _remoteMortality.insertBatch(models);
      successIds.addAll(mResult.successIds);
      failedIds.addAll(mResult.failedIds);
    }

    // استهلاك العلف
    final consumptions =
        records.where((r) => r.tableName == 'feed_consumption').toList();
    if (consumptions.isNotEmpty) {
      final models =
          consumptions.map((r) => FeedConsumptionModel.fromJson(r.payload)).toList();
      final cResult = await _remoteFeed.insertConsumptionBatch(models);
      successIds.addAll(cResult.successIds);
      failedIds.addAll(cResult.failedIds);
    }

    // استلام العلف
    final received = records.where((r) => r.tableName == 'feed_received').toList();
    if (received.isNotEmpty) {
      final models =
          received.map((r) => FeedReceivedModel.fromJson(r.payload)).toList();
      final rResult = await _remoteFeed.insertReceivedBatch(models);
      successIds.addAll(rResult.successIds);
      failedIds.addAll(rResult.failedIds);
    }

    // تخريج
    final dispatches =
        records.where((r) => r.tableName == 'egg_dispatch').toList();
    if (dispatches.isNotEmpty) {
      final models =
          dispatches.map((r) => DispatchModel.fromJson(r.payload)).toList();
      final dResult = await _remoteDispatch.insertBatch(models);
      successIds.addAll(dResult.successIds);
      failedIds.addAll(dResult.failedIds);
    }

    // أدوية
    final medications =
        records.where((r) => r.tableName == 'medications').toList();
    if (medications.isNotEmpty) {
      final models =
          medications.map((r) => MedicationModel.fromJson(r.payload)).toList();
      final medResult = await _remoteMedication.insertBatch(models);
      successIds.addAll(medResult.successIds);
      failedIds.addAll(medResult.failedIds);
    }

    // مدفوعات
    final payments =
        records.where((r) => r.tableName == 'payments').toList();
    if (payments.isNotEmpty) {
      final models =
          payments.map((r) => PaymentModel.fromJson(r.payload)).toList();
      final payResult = await _remotePayment.insertBatch(models);
      successIds.addAll(payResult.successIds);
      failedIds.addAll(payResult.failedIds);
    }

    // زبائن (UPSERT بنفس المعرّف)
    final customers =
        records.where((r) => r.tableName == 'customers').toList();
    if (customers.isNotEmpty) {
      for (final record in customers) {
        try {
          final model = CustomerModel.fromJson(record.payload);
          await _remoteDispatch.insertCustomer(record.recordId, model);
          successIds.add(record.id ?? record.recordId);
        } catch (_) {
          failedIds.add(record.id ?? record.recordId);
        }
      }
    }

    // تسجيل في طابور المزامنة (upsert لتجنب التكرار)
    for (final record in records) {
      if (record.id == null) continue;
      final status = successIds.contains(record.id) ? 'synced' : 'failed';
      final existing = await _syncQueueDao.findByRecordId(record.recordId);
      if (existing != null) {
        await _syncQueueDao.updateStatus(record.recordId, status);
      } else {
        await _syncQueueDao.insert(
          tableName: record.tableName,
          recordId: record.recordId,
          payload: record.payload,
          userId: '',
        );
        await _syncQueueDao.updateStatus(record.recordId, status);
      }
    }

    // تنظيف السجلات القديمة المتزامنة
    try {
      await _syncQueueDao.cleanSynced(olderThanDays: 3);
    } catch (_) {}

    return BatchUploadResult(successIds: successIds, failedIds: failedIds);
  }

  @override
  Future<void> markAsSynced(String id) async {
    await _eggDao.updateSyncStatus(id, SyncStatus.synced);
    await _mortalityDao.updateSyncStatus(id, SyncStatus.synced);
    await _feedDao.updateConsumptionSyncStatus(id, SyncStatus.synced);
    await _feedDao.updateReceivedSyncStatus(id, SyncStatus.synced);
    await _dispatchDao.updateSyncStatus(id, SyncStatus.synced);
    await _medicationDao.updateSyncStatus(id, SyncStatus.synced);
    await _customerDao.updateSyncStatus(id, SyncStatus.synced);
    await _syncQueueDao.updateStatus(id, 'synced');
  }

  @override
  Future<void> markAsFailed(String id, String? error) async {
    await _eggDao.updateSyncStatus(id, SyncStatus.failed);
    await _mortalityDao.updateSyncStatus(id, SyncStatus.failed);
    await _feedDao.updateConsumptionSyncStatus(id, SyncStatus.failed);
    await _feedDao.updateReceivedSyncStatus(id, SyncStatus.failed);
    await _dispatchDao.updateSyncStatus(id, SyncStatus.failed);
    await _medicationDao.updateSyncStatus(id, SyncStatus.failed);
    await _customerDao.updateSyncStatus(id, SyncStatus.failed);
    await _syncQueueDao.updateStatus(id, 'failed');
  }

  @override
  Future<void> incrementAttempts(String id) async {
    await _syncQueueDao.incrementAttempts(id);
  }

  @override
  Future<Map<String, dynamic>?> getRemoteRecord(String table, String id) async {
    try {
      final data = await _remoteEgg.client
          .from(table)
          .select()
          .eq('id', id)
          .maybeSingle();
      if (data == null) return null;
      return Map<String, dynamic>.from(data);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> replaceLocalWithRemote(SyncRecord local, Map<String, dynamic> remote) async {
    final table = local.tableName;
    switch (table) {
      case 'egg_production':
        final model = EggProductionModel.fromJson(remote);
        await _eggDao.replaceWithRemote(model);
        break;
      case 'mortality':
        final model = MortalityModel.fromJson(remote);
        await _mortalityDao.replaceWithRemote(model);
        break;
      case 'feed_consumption':
        final model = FeedConsumptionModel.fromJson(remote);
        await _feedDao.replaceConsumptionWithRemote(model);
        break;
      case 'feed_received':
        final model = FeedReceivedModel.fromJson(remote);
        await _feedDao.replaceReceivedWithRemote(model);
        break;
      case 'egg_dispatch':
        final model = DispatchModel.fromJson(remote);
        await _dispatchDao.replaceWithRemote(model);
        break;
      case 'medications':
        final model = MedicationModel.fromJson(remote);
        await _medicationDao.replaceWithRemote(model);
        break;
      default:
        break;
    }
  }

  @override
  Future<void> forceUpload(SyncRecord record) async {
    await uploadBatch([record]);
  }

  @override
  Future<void> logError(String error) async {
    await _syncQueueDao.insertError(error);
  }
}
