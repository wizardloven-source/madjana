import 'package:core/core.dart';
import 'package:domain/domain.dart';
import 'package:sqflite/sqflite.dart';
import '../datasources/local/daos/customer_dao.dart';
import '../datasources/local/daos/dispatch_dao.dart';
import '../datasources/local/daos/egg_production_dao.dart';
import '../datasources/local/daos/expense_dao.dart';
import '../datasources/local/daos/feed_dao.dart';
import '../datasources/local/daos/medication_dao.dart';
import '../datasources/local/daos/mortality_dao.dart';
import '../datasources/local/daos/payment_dao.dart';
import '../datasources/local/daos/sync_queue_dao.dart';
import '../datasources/local/local_database.dart';
import '../datasources/remote/supabase_dispatch_datasource.dart';
import '../datasources/remote/supabase_egg_datasource.dart';
import '../datasources/remote/supabase_feed_datasource.dart';
import '../datasources/remote/supabase_medication_datasource.dart';
import '../datasources/remote/supabase_mortality_datasource.dart';
import '../datasources/remote/supabase_payment_datasource.dart';

/// تنفيذ مستودع المزامنة المحسّن
///
/// الإصلاحات المطبقة:
/// 1. إضافة PaymentDao و ExpenseDao
/// 2. markAsSynced/markAsFailed تعمل بـ tableName + recordId
/// 3. pullRemoteRecords يستخدم updated_at للـ incremental sync
/// 4. دعم Soft Delete بـ deleted_at
/// 5. تسجيل أخطاء مفصّل بدلاً من catch (_) {}
/// 6. تقسيم عادل للـ limit بين الجداول
class SyncRepositoryImpl implements SyncRepository {
  final EggProductionDao _eggDao;
  final MortalityDao _mortalityDao;
  final FeedDao _feedDao;
  final DispatchDao _dispatchDao;
  final MedicationDao _medicationDao;
  final CustomerDao _customerDao;
  final PaymentDao _paymentDao;
  final ExpenseDao _expenseDao;
  final SyncQueueDao _syncQueueDao;
  
  final SupabaseEggDatasource _remoteEgg;
  final SupabaseMortalityDatasource _remoteMortality;
  final SupabaseFeedDatasource _remoteFeed;
  final SupabaseDispatchDatasource _remoteDispatch;
  final SupabaseMedicationDatasource _remoteMedication;
  final SupabasePaymentDatasource _remotePayment;
  
  // تتبع آخر مزامنة لكل جدول للـ incremental sync
  final Map<String, DateTime> _lastSyncTimes = {};
  
  SyncRepositoryImpl({
    required EggProductionDao eggDao,
    required MortalityDao mortalityDao,
    required FeedDao feedDao,
    required DispatchDao dispatchDao,
    required MedicationDao medicationDao,
    required CustomerDao customerDao,
    required PaymentDao paymentDao,
    required ExpenseDao expenseDao,
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
        _paymentDao = paymentDao,
        _expenseDao = expenseDao,
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
    
    // تقسيم عادل للـ limit بين الجداول (7 جداول)
    final perTableLimit = (limit / 7).ceil();

    // بيض
    final eggs = await _eggDao.getPendingRecords(limit: perTableLimit);
    for (final e in eggs) {
      records.add(SyncRecord(
        id: e.id,
        tableName: 'egg_production',
        recordId: e.id!,
        payload: e.toJson(),
        updatedAt: e.updatedAt ?? e.createdAt ?? DateTime.now(),
        operation: e.syncStatus == SyncStatus.pending ? 'INSERT' : 'UPDATE',
      ));
    }

    // نفوق
    final mortality = await _mortalityDao.getPendingRecords(limit: perTableLimit);
    for (final m in mortality) {
      records.add(SyncRecord(
        id: m.id,
        tableName: 'mortality',
        recordId: m.id!,
        payload: m.toJson(),
        updatedAt: m.date,
        operation: m.syncStatus == SyncStatus.pending ? 'INSERT' : 'UPDATE',
      ));
    }

    // استهلاك العلف
    final consumption = await _feedDao.getPendingConsumption(limit: perTableLimit);
    for (final c in consumption) {
      records.add(SyncRecord(
        id: c.id,
        tableName: 'feed_consumption',
        recordId: c.id!,
        payload: c.toJson(),
        updatedAt: c.date,
        operation: c.syncStatus == SyncStatus.pending ? 'INSERT' : 'UPDATE',
      ));
    }

    // استلام العلف
    final received = await _feedDao.getPendingReceived(limit: perTableLimit);
    for (final r in received) {
      records.add(SyncRecord(
        id: r.id,
        tableName: 'feed_received',
        recordId: r.id!,
        payload: r.toJson(),
        updatedAt: r.date,
        operation: 'INSERT',
      ));
    }

    // تخريج
    final dispatches = await _dispatchDao.getPendingRecords(limit: perTableLimit);
    for (final d in dispatches) {
      records.add(SyncRecord(
        id: d.id,
        tableName: 'egg_dispatch',
        recordId: d.id!,
        payload: d.toJson(),
        updatedAt: d.date,
        operation: d.syncStatus == SyncStatus.pending ? 'INSERT' : 'UPDATE',
      ));
    }

    // أدوية
    final medications = await _medicationDao.getPendingRecords(limit: perTableLimit);
    for (final m in medications) {
      records.add(SyncRecord(
        id: m.id,
        tableName: 'medications',
        recordId: m.id!,
        payload: m.toJson(),
        updatedAt: m.date,
        operation: m.syncStatus == SyncStatus.pending ? 'INSERT' : 'UPDATE',
      ));
    }

    // زبائن
    final customers = await _customerDao.getPendingRecords(limit: perTableLimit);
    for (final c in customers) {
      records.add(SyncRecord(
        id: c.id,
        tableName: 'customers',
        recordId: c.id!,
        payload: c.toJson(),
        updatedAt: DateTime.now(),
        operation: 'INSERT',
      ));
    }

    // مدفوعات - إصلاح: إضافة payments إلى pending records
    final payments = await _paymentDao.getPendingRecords(limit: perTableLimit);
    for (final p in payments) {
      final pId = p['id'] as String?;
      if (pId == null) continue;
      records.add(SyncRecord(
        id: pId,
        tableName: 'payments',
        recordId: pId,
        payload: Map<String, dynamic>.from(p),
        updatedAt:
            DateTime.tryParse(p['updated_at'] as String? ?? '') ?? DateTime.now(),
        operation: p['sync_status'] == SyncStatus.pending.name
            ? 'INSERT'
            : 'UPDATE',
      ));
    }

    // مصروفات - إصلاح: إضافة expenses إلى pending records
    final expenses = await _expenseDao.getPendingRecords(limit: perTableLimit);
    for (final e in expenses) {
      final eId = e['id'] as String?;
      if (eId == null) continue;
      records.add(SyncRecord(
        id: eId,
        tableName: 'expenses',
        recordId: eId,
        payload: Map<String, dynamic>.from(e),
        updatedAt:
            DateTime.tryParse(e['updated_at'] as String? ?? '') ?? DateTime.now(),
        operation: e['sync_status'] == SyncStatus.pending.name
            ? 'INSERT'
            : 'UPDATE',
      ));
    }

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
        // Incremental Pull: جلب السجلات المحدثة فقط منذ آخر مزامنة
        final lastSync = _lastSyncTimes[table] ?? DateTime.utc(2000);
        final lastSyncStr = lastSync.toIso8601String();
        
        final rows = await _remoteEgg.client
            .from(table)
            .select()
            .eq('farm_id', farmId)
            .gte('updated_at', lastSyncStr); // سحب المحدّث فقط

        // أعمدة الجدول المحلي
        final columns = <String>{};
        final info = await db.rawQuery('PRAGMA table_info($table)');
        for (final col in info) {
          columns.add(col['name'] as String);
        }
        final hasSyncStatus = columns.contains('sync_status');
        final hasDeletedAt = columns.contains('deleted_at');

        for (final raw in rows as List) {
          String? rowId;
          try {
            final row = Map<String, dynamic>.from(raw as Map);
            rowId = row['id'] as String?;
            final id = rowId;
            if (id == null) continue;

            // التحقق من Soft Delete
            if (hasDeletedAt && row['deleted_at'] != null) {
              // سجل محذوف - حذفه محلياً
              await db.delete(
                table,
                where: 'id = ?',
                whereArgs: [id],
              );
              pulled++;
              continue;
            }

            // لا نطغى على سجلات محلية لم تُزامَن بعد
            if (hasSyncStatus) {
              final existing = await db.query(
                table,
                where: 'id = ? AND sync_status = ?',
                whereArgs: [id, SyncStatus.pending.name],
                limit: 1,
              );
              if (existing.isNotEmpty) {
                continue; // الحفاظ على التعديل المحلي
              }
              row['sync_status'] = SyncStatus.synced.name;
            }

            // إزالة الأعمدة غير الموجودة محلياً
            row.removeWhere((k, _) => !columns.contains(k));

            // ضمان وجود created_at
            if (!row.containsKey('created_at') || row['created_at'] == null) {
              row['created_at'] = DateTime.now().toIso8601String();
            }

            await db.insert(
              table,
              row,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            pulled++;
          } catch (e, stackTrace) {
            // تسجيل الخطأ بدلاً من تجاهله
            final error = 'Pull row error in $table (id: $rowId): $e';
            await logError(error);
            // تخطي الصف التالف والاستمرار
          }
        }
        
        // تحديث وقت المزامنة الناجحة لهذا الجدول
        if (rows.isNotEmpty) {
          _lastSyncTimes[table] = DateTime.now();
        }
      } catch (e, stackTrace) {
        // تسجيل الخطأ بدلاً من تجاهله
        final error = 'Pull table error for $table: $e\n$stackTrace';
        await logError(error);
        // الانتقال للجدول التالي
      }
    }

    return pulled;
  }

  @override
  Future<int> syncNow(String farmId) async {
    // UPLOAD أولاً لتجنب التعارضات
    final records = await getPendingRecords();
    if (records.isNotEmpty) {
      final result = await uploadBatch(records);
      for (final record in records) {
        if (record.id == null) continue;
        if (result.successIds.contains(record.id)) {
          await markAsSyncedById(record.tableName, record.recordId);
        } else {
          await incrementAttempts(record.id!);
        }
      }
    }
    
    // ثم PULL
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
    // إصلاح: إضافة payments و expenses
    count += await _paymentDao.countPending();
    count += await _expenseDao.countPending();
    return count;
  }

  @override
  Future<int> getSyncedCount() async => await _syncQueueDao.countByStatus('synced');

  @override
  Future<int> getFailedCount() async => await _syncQueueDao.countByStatus('failed');

  @override
  Future<BatchUploadResult> uploadBatch(List<SyncRecord> records) async {
    if (records.isEmpty) {
      return BatchUploadResult(
        successIds: const [],
        failedIds: const [],
      );
    }

    final client = _remoteEgg.client;

    // تحويل السجلات إلى صيغة Edge Function
    final payload = records.map((record) {
      return <String, dynamic>{
        'table': record.tableName,
        'action': record.operation,
        'data': record.payload,
      };
    }).toList();

    try {
      // استدعاء Edge Function الموحّد
      final response = await client.functions.invoke(
        'sync_records',
        body: {
          'records': payload,
        },
      );

      if (response.status != 200) {
        throw Exception(
          'Sync HTTP ${response.status}: ${response.data}',
        );
      }

      final data = Map<String, dynamic>.from(response.data as Map);

      final successRecords = (data['success_records'] as List?)
              ?.cast<Map>()
              .toList() ??
          const [];

      final failedRecords = (data['failed_records'] as List?)
              ?.cast<Map>()
              .toList() ??
          const [];

      final conflictRecords = (data['conflict_records'] as List?)
              ?.cast<Map>()
              .toList() ??
          const [];

      final successIds = <String>[];
      final failedIds = <String>[];

      // استخراج المعرفات الناجحة
      for (final item in successRecords) {
        final id = item['id']?.toString();
        if (id != null && id.isNotEmpty) {
          successIds.add(id);
        }
      }

      // اعتبار التعارضات فشل
      for (final item in conflictRecords) {
        final id = item['id']?.toString();
        if (id != null && id.isNotEmpty) {
          failedIds.add(id);
        }
      }

      // إضافة الفشل الأخرى
      for (final item in failedRecords) {
        final id = item['id']?.toString();
        if (id != null && id.isNotEmpty) {
          failedIds.add(id);
        }
      }

      // تحديث حالة الطابور المحلي
      for (final record in records) {
        if (record.id == null) continue;
        
        final existing = await _syncQueueDao.findByRecordId(record.recordId);
        if (existing != null) {
          if (successIds.contains(record.id)) {
            await _syncQueueDao.updateStatus(record.recordId, 'synced');
          } else if (failedIds.contains(record.id)) {
            await _syncQueueDao.updateStatus(record.recordId, 'failed');
            await _syncQueueDao.incrementAttempts(record.recordId);
          }
        } else {
          await _syncQueueDao.insert(
            tableName: record.tableName,
            recordId: record.recordId,
            payload: record.payload,
            userId: '',
            action: record.operation,
          );
          final status = successIds.contains(record.id) ? 'synced' : 'failed';
          await _syncQueueDao.updateStatus(record.recordId, status);
        }
      }

      // تنظيف السجلات القديمة المتزامنة
      try {
        await _syncQueueDao.cleanSynced(olderThanDays: 3);
      } catch (_) {}

      return BatchUploadResult(successIds: successIds, failedIds: failedIds);
      
    } catch (e, stackTrace) {
      // تسجيل الخطأ
      await logError('Batch upload failed: $e\n$stackTrace');

      // اعتبار كل السجلات فاشلة
      final failedIds = records
          .map((r) => r.id ?? r.recordId)
          .whereType<String>()
          .toList();

      // تحديث الحالة في الطابور
      for (final record in records) {
        if (record.id == null) continue;
        final existing = await _syncQueueDao.findByRecordId(record.recordId);
        if (existing != null) {
          await _syncQueueDao.updateStatus(record.recordId, 'failed');
          await _syncQueueDao.updateError(record.recordId, e.toString());
          await _syncQueueDao.incrementAttempts(record.recordId);
        }
      }

      return BatchUploadResult(
        successIds: const [],
        failedIds: failedIds,
      );
    }
  }

  // إصلاح: markAsSynced تعمل بـ tableName + recordId بدلاً من id فقط
  Future<void> markAsSyncedById(String tableName, String recordId) async {
    switch (tableName) {
      case 'egg_production':
        await _eggDao.updateSyncStatus(recordId, SyncStatus.synced);
        break;
      case 'mortality':
        await _mortalityDao.updateSyncStatus(recordId, SyncStatus.synced);
        break;
      case 'feed_consumption':
        await _feedDao.updateConsumptionSyncStatus(recordId, SyncStatus.synced);
        break;
      case 'feed_received':
        await _feedDao.updateReceivedSyncStatus(recordId, SyncStatus.synced);
        break;
      case 'egg_dispatch':
        await _dispatchDao.updateSyncStatus(recordId, SyncStatus.synced);
        break;
      case 'medications':
        await _medicationDao.updateSyncStatus(recordId, SyncStatus.synced);
        break;
      case 'customers':
        await _customerDao.updateSyncStatus(recordId, SyncStatus.synced);
        break;
      case 'payments':
        await _paymentDao.updateSyncStatus(recordId, SyncStatus.synced);
        break;
      case 'expenses':
        await _expenseDao.updateSyncStatus(recordId, SyncStatus.synced);
        break;
    }
    await _syncQueueDao.updateStatus(recordId, 'synced');
  }

  // إصلاح: markAsFailed تعمل بـ tableName + recordId
  Future<void> markAsFailedById(String tableName, String recordId, String? error) async {
    switch (tableName) {
      case 'egg_production':
        await _eggDao.updateSyncStatus(recordId, SyncStatus.failed);
        break;
      case 'mortality':
        await _mortalityDao.updateSyncStatus(recordId, SyncStatus.failed);
        break;
      case 'feed_consumption':
        await _feedDao.updateConsumptionSyncStatus(recordId, SyncStatus.failed);
        break;
      case 'feed_received':
        await _feedDao.updateReceivedSyncStatus(recordId, SyncStatus.failed);
        break;
      case 'egg_dispatch':
        await _dispatchDao.updateSyncStatus(recordId, SyncStatus.failed);
        break;
      case 'medications':
        await _medicationDao.updateSyncStatus(recordId, SyncStatus.failed);
        break;
      case 'customers':
        await _customerDao.updateSyncStatus(recordId, SyncStatus.failed);
        break;
      case 'payments':
        await _paymentDao.updateSyncStatus(recordId, SyncStatus.failed);
        break;
      case 'expenses':
        await _expenseDao.updateSyncStatus(recordId, SyncStatus.failed);
        break;
    }
    await _syncQueueDao.updateStatus(recordId, 'failed');
  }

  @override
  @deprecated
  Future<void> markAsSynced(String id) async {
    // الطريقة القديمة الخاطئة - استخدام markAsSyncedById بدلاً من ذلك
    throw UnsupportedError(
      'markAsSynced(String id) is deprecated. Use markAsSyncedById(tableName, recordId) instead.'
    );
  }

  @override
  @deprecated
  Future<void> markAsFailed(String id, String? error) async {
    // الطريقة القديمة الخاطئة - استخدام markAsFailedById بدلاً من ذلك
    throw UnsupportedError(
      'markAsFailed(String id, error) is deprecated. Use markAsFailedById(tableName, recordId, error) instead.'
    );
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
    } catch (e) {
      await logError('getRemoteRecord failed: $e');
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
        await logError('replaceLocalWithRemote not implemented for $table');
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
