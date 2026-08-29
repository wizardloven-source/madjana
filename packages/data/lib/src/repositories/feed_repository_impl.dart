import 'package:core/core.dart';
import 'package:domain/domain.dart';
import '../datasources/local/daos/feed_dao.dart';
import '../datasources/remote/supabase_feed_datasource.dart';

/// تنفيذ مستودع العلف
class FeedRepositoryImpl implements FeedRepository {
  final FeedDao _localDao;
  final SupabaseFeedDatasource _remoteDatasource;

  FeedRepositoryImpl({
    required FeedDao localDao,
    required SupabaseFeedDatasource remoteDatasource,
  })  : _localDao = localDao,
        _remoteDatasource = remoteDatasource;

  @override
  Future<void> saveConsumptionLocal(FeedConsumptionModel record) async {
    await _localDao.insertConsumption(record);
  }

  @override
  Future<void> saveReceivedLocal(FeedReceivedModel record) async {
    await _localDao.insertReceived(record.toJson());
  }

  @override
  Future<List<FeedConsumptionModel>> getTodayConsumption(String farmId) {
    return _localDao.getTodayConsumption(farmId);
  }

  @override
  Future<List<FeedConsumptionModel>> getAllConsumption({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) {
    return _localDao.getAllConsumption(
      farmId: farmId,
      fromDate: fromDate,
      toDate: toDate,
    );
  }

  @override
  Future<List<FeedReceivedModel>> getAllReceived({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) {
    return _localDao.getAllReceived(
      farmId: farmId,
      fromDate: fromDate,
      toDate: toDate,
    );
  }

  @override
  Future<void> syncPendingConsumption() async {
    final pending = await _localDao.getPendingConsumption();
    if (pending.isEmpty) return;

    final successIds = await _remoteDatasource.insertConsumptionBatch(pending);
    for (final record in pending) {
      if (record.id == null) continue;
      await _localDao.updateConsumptionSyncStatus(
        record.id!,
        successIds.successIds.contains(record.id)
            ? SyncStatus.synced
            : SyncStatus.failed,
      );
    }

    final pendingReceived = await _localDao.getPendingReceived();
    if (pendingReceived.isNotEmpty) {
      final receivedIds = await _remoteDatasource.insertReceivedBatch(pendingReceived);
      for (final record in pendingReceived) {
        if (record.id == null) continue;
        await _localDao.updateReceivedSyncStatus(
          record.id!,
          receivedIds.successIds.contains(record.id)
              ? SyncStatus.synced
              : SyncStatus.failed,
        );
      }
    }
  }

  @override
  Future<void> setReceivedPrice({
    required String id,
    required double pricePerKg,
  }) async {
    await _localDao.updateReceivedPrice(id, pricePerKg);
    try {
      await _remoteDatasource.updateReceivedPrice(id, pricePerKg);
    } catch (_) {
      // سيتم مزامنتها لاحقاً عند توفر الاتصال
    }
  }

  @override
  Future<double> getCurrentFeedStock(String farmId) async {
    final consumed = await _localDao.getAllConsumption(farmId: farmId);
    final received = await _localDao.getAllReceived(farmId: farmId);

    final totalReceived =
        received.fold<double>(0, (sum, r) => sum + r.quantityKg);
    final totalConsumed =
        consumed.fold<double>(0, (sum, r) => sum + r.quantityKg);

    return totalReceived - totalConsumed;
  }

  @override
  Future<void> deleteConsumptionRecord(String id) async {
    await _localDao.deleteConsumption(id);
    try {
      await _remoteDatasource.deleteConsumption(id);
    } catch (_) {
      // سيتم مزامنتها لاحقاً
    }
  }
}