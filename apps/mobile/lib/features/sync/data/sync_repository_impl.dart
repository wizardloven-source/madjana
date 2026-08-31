import 'package:core/core.dart';
import 'package:data/data.dart';

/// واجهة المزامنة الخاصة بالموبايل
abstract class MobileSyncRepository {
  Future<List<SyncChangeModel>> getPendingRecords({int limit = 50});
  Future<int> getPendingCount();
  Future<BatchSyncResult> uploadBatch(List<SyncChangeModel> records);
  Future<int> pullRemoteRecords(String farmId);
  Future<void> markAsSyncedById(String tableName, String recordId);
  Future<void> markAsFailedById(String tableName, String recordId, String error);
  Future<void> incrementAttempts(String id);
  Future<Map<String, dynamic>?> getRemoteRecord(String table, String id);
  Future<void> replaceLocalWithRemote(SyncChangeModel local, Map<String, dynamic> remote);
  Future<void> forceUpload(SyncChangeModel record);
  Future<void> logError(String error);
  Future<int> getSyncedCount();
  Future<int> getFailedCount();
}

/// تنفيذ الواجهة بالتفويض إلى طبقة البيانات
class MobileSyncRepositoryImpl implements MobileSyncRepository {
  final SyncRepository _delegate;

  MobileSyncRepositoryImpl(this._delegate);

  @override
  Future<List<SyncChangeModel>> getPendingRecords({int limit = 50}) =>
      _delegate.getPendingChanges(limit: limit);

  @override
  Future<int> getPendingCount() => _delegate.getPendingCount();

  @override
  Future<BatchSyncResult> uploadBatch(List<SyncChangeModel> records) =>
      _delegate.uploadBatch(records);

  @override
  Future<int> pullRemoteRecords(String farmId) =>
      _delegate.pullRemoteRecords(farmId);

  @override
  Future<void> markAsSyncedById(String tableName, String recordId) async {}

  @override
  Future<void> markAsFailedById(String tableName, String recordId, String error) async {}

  @override
  Future<void> incrementAttempts(String id) async {}

  @override
  Future<Map<String, dynamic>?> getRemoteRecord(String table, String id) async => null;

  @override
  Future<void> replaceLocalWithRemote(SyncChangeModel local, Map<String, dynamic> remote) async {}

  @override
  Future<void> forceUpload(SyncChangeModel record) async {}

  @override
  Future<void> logError(String error) async {}

  @override
  Future<int> getSyncedCount() async => 0;

  @override
  Future<int> getFailedCount() => _delegate.getFailedCount();
}
