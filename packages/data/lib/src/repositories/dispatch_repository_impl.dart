import 'package:core/core.dart';
import 'package:domain/domain.dart';
import '../datasources/local/daos/customer_dao.dart';
import '../datasources/local/daos/dispatch_dao.dart';
import '../datasources/remote/supabase_dispatch_datasource.dart';

/// تنفيذ مستودع التخريج والزبائن
class DispatchRepositoryImpl implements DispatchRepository {
  final DispatchDao _localDao;
  final CustomerDao _customerDao;
  final SupabaseDispatchDatasource _remoteDatasource;

  DispatchRepositoryImpl({
    required DispatchDao localDao,
    required CustomerDao customerDao,
    required SupabaseDispatchDatasource remoteDatasource,
  })  : _localDao = localDao,
        _customerDao = customerDao,
        _remoteDatasource = remoteDatasource;

  @override
  Future<void> saveLocal(DispatchModel record) async {
    await _localDao.insert(record);
  }

  @override
  Future<String> addCustomer(CustomerModel customer) async {
    final localId = await _customerDao.insert(customer);
    try {
      await _remoteDatasource.insertCustomer(localId, customer);
      await _customerDao.updateSyncStatus(localId, SyncStatus.synced);
    } catch (_) {
      // Offline-first: يبقى pend في طابور المزامنة ويرتفع لاحقاً تلقائياً
    }
    return localId;
  }

  @override
  Future<List<CustomerModel>> getCustomers(String farmId) {
    return _customerDao.getByFarm(farmId);
  }

  @override
  Future<List<CustomerModel>> syncCustomersFromRemote(String farmId) async {
    final remote = await _remoteDatasource.getCustomers(farmId);
    for (final customer in remote) {
      await _customerDao.upsertFromRemote(customer);
    }
    return _customerDao.getByFarm(farmId);
  }

  @override
  Future<void> updateCustomer(CustomerModel customer) async {
    await _customerDao.update(customer);
    try {
      await _remoteDatasource.updateCustomer(customer);
    } catch (_) {
      // يبقى محلياً وينتظر المزامنة القادمة
    }
  }

  @override
  Future<void> deleteCustomer(String id) async {
    await _customerDao.deleteById(id);
    try {
      await _remoteDatasource.deleteCustomer(id);
    } catch (_) {
      // يبقى محذوفاً محلياً على الأقل
    }
  }

  @override
  Future<List<DispatchModel>> getAll({
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
  Future<void> syncPendingRecords() async {
    final pending = await _localDao.getPendingRecords();
    if (pending.isEmpty) return;

    final successIds = await _remoteDatasource.insertBatch(pending);
    for (final record in pending) {
      if (record.id == null) continue;
      await _localDao.updateSyncStatus(
        record.id!,
        successIds.successIds.contains(record.id)
            ? SyncStatus.synced
            : SyncStatus.failed,
      );
    }
  }

  @override
  Future<int> getPendingCount() => _localDao.countPending();
}