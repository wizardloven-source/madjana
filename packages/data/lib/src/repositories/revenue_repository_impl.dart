import 'package:core/core.dart';
import '../datasources/local/daos/revenue_dao.dart';
import '../datasources/remote/supabase_revenue_datasource.dart';

class RevenueRepositoryImpl implements RevenueRepository {
  final RevenueDao _localDao;
  final SupabaseRevenueDatasource _remoteDatasource;

  RevenueRepositoryImpl({
    required RevenueDao localDao,
    required SupabaseRevenueDatasource remoteDatasource,
  })  : _localDao = localDao,
        _remoteDatasource = remoteDatasource;

  @override
  Future<List<RevenueModel>> getRevenues({
    required String farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    try {
      final revenues = await _remoteDatasource.getRevenues(
        farmId: farmId,
        fromDate: fromDate,
        toDate: toDate,
      );
      if (fromDate == null && toDate == null) {
        await _localDao.saveAll(revenues, farmId);
      }
      return revenues;
    } catch (_) {
      return _localDao.getAll(
        farmId: farmId,
        fromDate: fromDate,
        toDate: toDate,
      );
    }
  }

  @override
  Future<void> save(RevenueModel revenue) async {
    if (revenue.id == null) {
      final localId = await _localDao.insert(revenue.copyWith(syncStatus: SyncStatus.pending));
      try {
        final saved = await _remoteDatasource.insert(revenue.copyWith(id: localId));
        await _localDao.update(localId, RevenueModel.fromJson(saved).copyWith(syncStatus: SyncStatus.synced));
      } catch (_) {}
    } else {
      await _localDao.update(revenue.id!, revenue.copyWith(syncStatus: SyncStatus.pending));
      try {
        await _remoteDatasource.update(revenue.id!, revenue);
        await _localDao.update(revenue.id!, revenue.copyWith(syncStatus: SyncStatus.synced));
      } catch (_) {}
    }
  }

  @override
  Future<void> delete(String id) async {
    await _localDao.delete(id);
    try {
      await _remoteDatasource.delete(id);
    } catch (_) {}
  }

  @override
  Future<void> syncPendingRecords() async {
    final pending = await _localDao.getPendingModels();
    if (pending.isEmpty) return;

    for (final revenue in pending) {
      final id = revenue.id;
      if (id == null) continue;
      try {
        await _remoteDatasource.insert(revenue);
        await _localDao.updateSyncStatus(id, SyncStatus.synced);
      } catch (_) {}
    }
  }

  @override
  Future<double> getTotal({
    required String farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final revenues = await getRevenues(
      farmId: farmId,
      fromDate: fromDate,
      toDate: toDate,
    );
    return revenues.fold<double>(0, (sum, r) => sum + r.amount);
  }
}
