import 'package:core/core.dart';
import '../datasources/local/daos/settings_dao.dart';
import '../datasources/remote/supabase_farm_datasource.dart';

/// مفاتيح الإعدادات المحلية
class AppSettingsKeys {
  static const String currency = 'currency';
  static const String eggsPerCarton = 'eggs_per_carton';
  static const String eggsPerTray = 'eggs_per_tray';
  static const String feedBagWeight = 'feed_bag_weight_kg';
  static const String defaultMortalityRate = 'default_mortality_rate';
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

  @override
  Future<double> getFeedBagWeightKg() async {
    final value = await _settingsDao.get(AppSettingsKeys.feedBagWeight);
    return value != null ? double.tryParse(value) ?? 50.0 : 50.0;
  }

  @override
  Future<void> setFeedBagWeightKg(double weightKg) async {
    await _settingsDao.set(AppSettingsKeys.feedBagWeight, weightKg.toString());
  }

  @override
  Future<int> getEggsPerCarton() async {
    final value = await _settingsDao.get(AppSettingsKeys.eggsPerCarton);
    return value != null ? int.tryParse(value) ?? 360 : 360;
  }

  @override
  Future<void> setEggsPerCarton(int count) async {
    await _settingsDao.set(AppSettingsKeys.eggsPerCarton, count.toString());
  }

  @override
  Future<int> getEggsPerTray() async {
    final value = await _settingsDao.get(AppSettingsKeys.eggsPerTray);
    return value != null ? int.tryParse(value) ?? 30 : 30;
  }

  @override
  Future<void> setEggsPerTray(int count) async {
    await _settingsDao.set(AppSettingsKeys.eggsPerTray, count.toString());
  }

  @override
  Future<double> getDefaultMortalityRate() async {
    final value = await _settingsDao.get(AppSettingsKeys.defaultMortalityRate);
    return value != null ? double.tryParse(value) ?? 0.0 : 0.0;
  }

  @override
  Future<void> setDefaultMortalityRate(double rate) async {
    await _settingsDao.set(AppSettingsKeys.defaultMortalityRate, rate.toString());
  }
}
