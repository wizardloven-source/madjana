import 'package:core/core.dart';
import 'package:domain/domain.dart';
import '../datasources/local/daos/egg_production_dao.dart';
import '../datasources/remote/supabase_egg_datasource.dart';

/// تنفيذ مستودع إنتاج البيض
/// 
/// الآلية (Offline-first):
/// 1. الحفظ دائماً في SQLite أولاً
/// 2. وضع sync_status = pending
/// 3. SyncEngine يرفعها لاحقاً
class EggProductionRepositoryImpl implements EggProductionRepository {
  final EggProductionDao _localDao;
  final SupabaseEggDatasource _remoteDatasource;

  EggProductionRepositoryImpl({
    required EggProductionDao localDao,
    required SupabaseEggDatasource remoteDatasource,
  })  : _localDao = localDao,
        _remoteDatasource = remoteDatasource;

  @override
  Future<void> saveLocal(EggProductionModel record) async {
    // الحفظ محلياً فقط (المزامنة تتم عبر SyncEngine)
    await _localDao.insert(record);
  }

  @override
  Future<List<EggProductionModel>> getTodayRecords(String farmId) {
    return _localDao.getTodayRecords(farmId);
  }

  @override
  Future<EggProductionModel?> getRecordByDate(String farmId, DateTime date) {
    return _localDao.getByDate(farmId, date);
  }

  @override
  Future<void> syncPendingRecords() async {
    final pending = await _localDao.getPendingRecords();
    if (pending.isEmpty) return;

    final result = await _remoteDatasource.insertBatch(pending);

    // تحديث حالة كل سجل
    for (final record in pending) {
      if (record.id == null) continue;
      if (result.successIds.contains(record.id)) {
        await _localDao.updateSyncStatus(record.id!, SyncStatus.synced);
      } else {
        await _localDao.updateSyncStatus(record.id!, SyncStatus.failed);
      }
    }
  }

  @override
  Future<List<EggProductionModel>> getAllRecords({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) {
    return _localDao.getAll(
      farmId: farmId,
      fromDate: fromDate,
      toDate: toDate,
    );
  }

  @override
  Future<void> deleteRecord(String id) async {
    await _localDao.delete(id);
    try {
      await _remoteDatasource.delete(id);
    } catch (_) {
      // سيتم مزامنتها لاحقاً
    }
  }

  /// عدد السجلات المعلقة (لـ UI)
  Future<int> getPendingCount() => _localDao.countPending();
}