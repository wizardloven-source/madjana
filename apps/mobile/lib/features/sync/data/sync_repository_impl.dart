import 'package:domain/domain.dart';

/// واجهة المزامنة الخاصة بالموبايل
///
/// تجمع بين واجهة المزامنة الأساسية وإدارة طابور المزامنة.
abstract class MobileSyncRepository {
  Future<List<SyncRecord>> getPendingRecords({int limit = 50});

  Future<int> getPendingCount();

  Future<BatchUploadResult> uploadBatch(List<SyncRecord> records);

  /// سحب السجلات البعيدة إلى القاعدة المحلية
  Future<int> pullRemoteRecords(String farmId);

  Future<void> markAsSynced(String id);

  Future<void> markAsFailed(String id, String? error);

  Future<void> incrementAttempts(String id);

  Future<Map<String, dynamic>?> getRemoteRecord(String table, String id);

  Future<void> replaceLocalWithRemote(SyncRecord local, Map<String, dynamic> remote);

  Future<void> forceUpload(SyncRecord record);

  Future<void> logError(String error);

  Future<int> getSyncedCount();

  Future<int> getFailedCount();
}

/// تنفيذ الواجهة بالتفويض إلى طبقة البيانات
class MobileSyncRepositoryImpl implements MobileSyncRepository {
  final SyncRepository _delegate;

  MobileSyncRepositoryImpl(this._delegate);

  @override
  Future<List<SyncRecord>> getPendingRecords({int limit = 50}) =>
      _delegate.getPendingRecords(limit: limit);

  @override
  Future<int> getPendingCount() => _delegate.getPendingCount();

  @override
  Future<BatchUploadResult> uploadBatch(List<SyncRecord> records) =>
      _delegate.uploadBatch(records);

  @override
  Future<int> pullRemoteRecords(String farmId) =>
      _delegate.pullRemoteRecords(farmId);

  @override
  Future<void> markAsSynced(String id) => _delegate.markAsSynced(id);

  @override
  Future<void> markAsFailed(String id, String? error) =>
      _delegate.markAsFailed(id, error);

  @override
  Future<void> incrementAttempts(String id) => _delegate.incrementAttempts(id);

  @override
  Future<Map<String, dynamic>?> getRemoteRecord(String table, String id) =>
      _delegate.getRemoteRecord(table, id);

  @override
  Future<void> replaceLocalWithRemote(SyncRecord local, Map<String, dynamic> remote) =>
      _delegate.replaceLocalWithRemote(local, remote);

  @override
  Future<void> forceUpload(SyncRecord record) => _delegate.forceUpload(record);

  @override
  Future<void> logError(String error) => _delegate.logError(error);

  @override
  Future<int> getSyncedCount() => _delegate.getSyncedCount();

  @override
  Future<int> getFailedCount() => _delegate.getFailedCount();
}