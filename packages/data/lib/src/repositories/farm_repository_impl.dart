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
  static const String cartonLowThreshold = 'carton_low_threshold';
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
      final farm = await _remoteDatasource.getFarm(farmId)
          .timeout(const Duration(seconds: 10), onTimeout: () {
        throw Exception('انتهت مهلة الاتصال');
      });
      // نزامن الكاش المحلي مع قيم الخادم (المصدر: سطح مكتب المدير)
      await _settingsDao.set(
          AppSettingsKeys.feedBagWeight, farm.feedBagWeightKg.toString());
      await _settingsDao.set(
          AppSettingsKeys.eggsPerCarton, farm.eggsPerCarton.toString());
      await _settingsDao.set(
          AppSettingsKeys.eggsPerTray, farm.eggsPerTray.toString());
      await _settingsDao.set(
          AppSettingsKeys.defaultMortalityRate, farm.defaultMortalityRate.toString());
      await _settingsDao.set(
          AppSettingsKeys.cartonLowThreshold, farm.cartonLowThreshold.toString());
      return farm;
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

  @override
  Future<void> updateSettings(FarmModel farm) async {
    // المصدر: سطح مكتب المدير - نكتب الإعدادات في جدول المداجن (الخادم)
    // ليطّلع عليها الموبايل، مع تحديث الكاش المحلي كاحتياطي.
    await updateFarm(farm);
    await _settingsDao.set(
        AppSettingsKeys.feedBagWeight, farm.feedBagWeightKg.toString());
    await _settingsDao.set(AppSettingsKeys.eggsPerCarton, farm.eggsPerCarton.toString());
    await _settingsDao.set(AppSettingsKeys.eggsPerTray, farm.eggsPerTray.toString());
    await _settingsDao.set(
        AppSettingsKeys.defaultMortalityRate, farm.defaultMortalityRate.toString());
    await _settingsDao.set(
        AppSettingsKeys.cartonLowThreshold, farm.cartonLowThreshold.toString());
  }

  // ─────────────── الإعدادات المحلية ───────────────

  @override
  Future<AppCurrency> getInputCurrency() async {
    final value = await _settingsDao.get(AppSettingsKeys.currency);
    return AppCurrency.fromName(value ?? AppCurrency.dollar.name);
  }

  @override
  Future<void> setInputCurrency(AppCurrency currency) async {
    await _settingsDao.set(AppSettingsKeys.currency, currency.name);
  }

  @override
  Future<int> getCartonLowThreshold() async {
    final value = await _settingsDao.get(AppSettingsKeys.cartonLowThreshold);
    return value != null ? int.tryParse(value) ?? 100 : 100;
  }

  @override
  Future<void> setCartonLowThreshold(int trays) async {
    await _settingsDao.set(AppSettingsKeys.cartonLowThreshold, trays.toString());
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
