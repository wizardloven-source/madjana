import 'package:core/core.dart';
import '../datasources/local/daos/opening_balance_dao.dart';
import '../datasources/local/daos/flock_dao.dart';
import '../datasources/remote/supabase_opening_balance_datasource.dart';

/// تنفيذ مستودع الأرصدة الافتتاحية
class OpeningBalanceRepositoryImpl implements OpeningBalanceRepository {
  final OpeningBalanceDao _localDao;
  final FlockDao _flockDao;
  final SupabaseOpeningBalanceDatasource _remoteDatasource;

  OpeningBalanceRepositoryImpl({
    required OpeningBalanceDao localDao,
    required FlockDao flockDao,
    required SupabaseOpeningBalanceDatasource remoteDatasource,
  })  : _localDao = localDao,
        _flockDao = flockDao,
        _remoteDatasource = remoteDatasource;

  @override
  Future<OpeningBalanceModel?> getForFlock(String farmId, String flockId) async {
    try {
      final remote = await _remoteDatasource.getForFlock(farmId, flockId);
      if (remote != null) await _localDao.save(remote);
      return remote ?? await _localDao.getForFlock(farmId, flockId);
    } catch (_) {
      return _localDao.getForFlock(farmId, flockId);
    }
  }

  @override
  Future<List<OpeningBalanceModel>> getForFarm(String farmId) async {
    try {
      final remote = await _remoteDatasource.getForFarm(farmId);
      for (final b in remote) {
        await _localDao.save(b);
      }
      return remote;
    } catch (_) {
      return _localDao.getForFarm(farmId);
    }
  }

  @override
  Future<void> save(OpeningBalanceModel balance) async {
    await _localDao.save(balance);

    // P0: Recalculate flock.current_count = initial_count - openingBalance.mortalityCount
    // This ensures the flock reflects pre-system mortality immediately.
    try {
      final flock = await _flockDao.getById(balance.flockId);
      if (flock != null) {
        final newCount =
            (flock.initialCount - balance.mortalityCount).clamp(0, flock.initialCount);
        if (flock.currentCount != newCount) {
          await _flockDao.updateCurrentCount(flock.id, newCount);
        }
      }
    } catch (_) {
      // Best-effort: if flock update fails, sync trigger will fix it
    }

    try {
      await _remoteDatasource.upsert(balance);
    } catch (_) {
      // بدون اتصال: يبقى محلياً ويُرفع لاحقاً
    }
  }

  @override
  Future<void> delete(String farmId, String flockId) async {
    await _localDao.deleteForFlock(farmId, flockId);
    try {
      await _remoteDatasource.delete(farmId, flockId);
    } catch (_) {}
  }
}