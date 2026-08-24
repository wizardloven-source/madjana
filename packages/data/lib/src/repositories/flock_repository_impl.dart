import 'package:core/core.dart';
import '../datasources/local/daos/flock_dao.dart';
import '../datasources/remote/supabase_flock_datasource.dart';

/// تنفيذ مستودع القطعان - للمدير
///
/// القراءة: من الخادم مع تحديث الكاش المحلي، والرجوع للمحلي عند انقطاع الاتصال.
/// التعديل: يتطلب اتصالاً (القطعان مشتركة مع تطبيق العامل).
class FlockRepositoryImpl implements FlockRepository {
  final FlockDao _localDao;
  final SupabaseFlockDatasource _remoteDatasource;

  FlockRepositoryImpl({
    required FlockDao localDao,
    required SupabaseFlockDatasource remoteDatasource,
  })  : _localDao = localDao,
        _remoteDatasource = remoteDatasource;

  @override
  Future<List<FlockModel>> getFlocks(String farmId,
      {bool includeEnded = true}) async {
    try {
      final flocks = await _remoteDatasource.getFlocks(farmId);
      await _localDao.saveAll(flocks);
      return flocks;
    } catch (_) {
      // انقطاع اتصال: نعرض النسخة المحلية (النشطة فقط متوفرة محلياً)
      final local = await _localDao.getByFarm(farmId);
      if (includeEnded) {
        final all = await _localDao.getAll();
        return all.where((f) => f.farmId == farmId).toList();
      }
      return local;
    }
  }

  @override
  Future<void> createFlock(FlockModel flock) async {
    try {
      await _remoteDatasource.insert(flock);
      await _localDao.insert(flock);
    } catch (_) {
      throw Exception('تعذّر إنشاء القطيع - تأكد من الاتصال بالإنترنت');
    }
  }

  @override
  Future<void> updateFlock(FlockModel flock) async {
    try {
      await _remoteDatasource.update(flock);
      await _localDao.insert(flock);
    } catch (_) {
      throw Exception('تعذّر تعديل القطيع - تأكد من الاتصال بالإنترنت');
    }
  }

  @override
  Future<void> endFlock(String flockId) async {
    try {
      await _remoteDatasource.endFlock(flockId);
      await _localDao.markEnded(flockId);
    } catch (_) {
      throw Exception('تعذّر إنهاء الدورة - تأكد من الاتصال بالإنترنت');
    }
  }
}
