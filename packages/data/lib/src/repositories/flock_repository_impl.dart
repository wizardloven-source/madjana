import 'package:core/core.dart';
import 'package:uuid/uuid.dart';
import '../datasources/local/daos/flock_dao.dart';
import '../datasources/remote/supabase_flock_datasource.dart';

/// تنفيذ مستودع القطعان - للمدير
///
/// القراءة: من الخادم مع تحديث الكاش المحلي، والرجوع للمحلي عند انقطاع الاتصال.
/// التعديل: يتطلب اتصالاً (القطعان مشتركة مع تطبيق العامل).
class FlockRepositoryImpl implements FlockRepository {
  final FlockDao _localDao;
  final SupabaseFlockDatasource _remoteDatasource;

  static const _uuid = Uuid();

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
    // المعرّفات من واجهة المستخدم (millisecondsSinceEpoch) ليست UUID صالحاً
    // وتُرفض من قاعدة البيانات، وقد تتضارب عند النقر المزدوج.
    // نولّد UUID حقيقياً وفريداً في كل استدعاء.
    final f = _isValidUuid(flock.id) ? flock : _withFreshId(flock);
    // الحفظ محلياً أولاً (offline-first) حتى لا تُفقد البيانات عند انقطاع الشبكة
    await _localDao.insert(f);
    try {
      await _remoteDatasource.insert(f);
    } catch (_) {
      // غير متصل: بقي محلياً وسيُزامَن لاحقاً
    }
  }

  static bool _isValidUuid(String id) {
    final pattern = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
    return pattern.hasMatch(id);
  }

  static FlockModel _withFreshId(FlockModel flock) => FlockModel(
        id: _uuid.v4(),
        farmId: flock.farmId,
        breed: flock.breed,
        startDate: flock.startDate,
        initialCount: flock.initialCount,
        currentCount: flock.currentCount,
        status: flock.status,
        sectionsCount: flock.sectionsCount,
        version: flock.version,
        previousVersion: flock.previousVersion,
      );

  @override
  Future<void> updateFlock(FlockModel flock) async {
    await _localDao.insert(flock);
    try {
      await _remoteDatasource.update(flock);
    } catch (_) {
      // غير متصل: بقي محلياً وسيُزامَن لاحقاً
    }
  }

  @override
  Future<void> endFlock(String flockId) async {
    await _localDao.markEnded(flockId);
    try {
      await _remoteDatasource.endFlock(flockId);
    } catch (_) {
      // غير متصل: تحديث محلي فقط
    }
  }
}
