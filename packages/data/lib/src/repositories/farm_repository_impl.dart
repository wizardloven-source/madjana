import 'package:core/core.dart';
import '../datasources/local/daos/settings_dao.dart';
import '../datasources/remote/supabase_farm_datasource.dart';

/// مفاتيح الإعدادات المحلية
class AppSettingsKeys {
  static const String currency = 'currency';
  static const String eggsPerCarton = 'eggs_per_carton';
}

/// تنفيذ مستودع المدجنة والإعدادات - للمدير
class FarmRepositoryImpl implements FarmRepository {
  final SupabaseFarmDatasource _remoteDatasource;
  final SettingsDao _settingsDao;

  FarmRepositoryImpl({
    required SupabaseFarmDatasource remoteDatasource,
    required SettingsDao settingsDao,
  })  : _remoteDatasource = remoteDatasource,
        _settingsDao = settingsDao;

  @override
  Future<FarmModel> getFarm(String farmId) async {
    try {
      return await _remoteDatasource.getFarm(farmId)
          .timeout(const Duration(seconds: 10), onTimeout: () {
        throw Exception('انتهت مهلة الاتصال');
      });
    } catch (e) {
      return FarmModel(id: farmId, name: 'المدجنة');
    }
  }

  @override
  Future<void> updateFarm(FarmModel farm) async {
    try {
      await _remoteDatasource.update(farm)
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  // ─────────────── الإعدادات المحلية ───────────────

  @override
  Future<String> getCurrency() async {
    return await _settingsDao.get(AppSettingsKeys.currency) ?? 'ل.س';
  }

  @override
  Future<void> setCurrency(String symbol) async {
    await _settingsDao.set(AppSettingsKeys.currency, symbol);
  }
}
