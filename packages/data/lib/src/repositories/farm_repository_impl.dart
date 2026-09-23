import 'dart:convert';

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
  /// آخر لقطة كاملة لبيانات المدجنة (JSON) لإعادة رفعها عند الانقطاع.
  static const String farmSnapshot = 'farm_snapshot_json';
  /// '1' عندما تكون إعدادات المدجنة لم تصل للخادم بعد.
  static const String farmSettingsDirty = 'farm_settings_dirty';
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
      await _cacheFarm(farm);
      return farm;
    } catch (e) {
      // انقطاع الاتصال أو تعذّر الوصول للخادم: نُعيد آخر قيم محفوظة محلياً
      // بدل القيم الافتراضية، حتى لا يرجع وزن الكيس إلى 50 كغ ويضيع ما عدّله المدير.
      return _farmFromCache(farmId);
    }
  }

  /// مفتاح خاص بكل مدجنة حتى لا تتداخل إعداداتها (وزن الكيس...) بين المداجن.
  String _farmKey(String base, String farmId) => '$base::$farmId';

  /// كتابة قيم الخادم في الكاش المحلي الخاص بهذه المدجنة
  /// (لقطة كاملة + مفاتيح قديمة للتوافق مع قارئات عامة).
  Future<void> _cacheFarm(FarmModel farm) async {
    await _settingsDao.set(
        _farmKey(AppSettingsKeys.farmSnapshot, farm.id),
        jsonEncode(farm.toJson()));
    // مفاتيح عامة (احتياطية) تُبقي آخر قيم مقروءة لأي كود قديم.
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
  }

  /// بناء نموذج المدجنة من الكاش المحلي الخاص بهذه المدجنة عند تعذّر الخادم.
  Future<FarmModel> _farmFromCache(String farmId) async {
    final raw =
        await _settingsDao.get(_farmKey(AppSettingsKeys.farmSnapshot, farmId));
    if (raw != null && raw.isNotEmpty) {
      try {
        return FarmModel.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        // لقطة تالفة: نسقط إلى القيم الافتراضية أدناه.
      }
    }
    return FarmModel(id: farmId, name: 'المدجنة');
  }

  /// رفع إعدادات المدجنة للخادم — يُعيد نجاح العملية بدل ابتلاع الخطأ.
  Future<bool> _pushFarm(FarmModel farm) async {
    try {
      await _remoteDatasource.update(farm)
          .timeout(const Duration(seconds: 10));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> updateFarm(FarmModel farm) async {
    await _pushFarm(farm);
  }

  @override
  Future<void> updateSettings(FarmModel farm) async {
    // المصدر: سطح مكتب المدير - نكتب الإعدادات محلياً أولاً (Offline-first)
    // ثم نحاول رفعها للخادم ليطّلع عليها الموبايل. إن فشل الرفع نعلّمها
    // «معلّقة» ليُعاد رفعها تلقائياً في المزامنة الدورية.
    await _cacheFarm(farm);
    final ok = await _pushFarm(farm);
    await _settingsDao.set(
        _farmKey(AppSettingsKeys.farmSettingsDirty, farm.id), ok ? '0' : '1');
  }

  @override
  Future<bool> pushPendingSettings(String farmId) async {
    final dirtyKey = _farmKey(AppSettingsKeys.farmSettingsDirty, farmId);
    final dirty = await _settingsDao.get(dirtyKey);
    if (dirty != '1') return true;
    final raw =
        await _settingsDao.get(_farmKey(AppSettingsKeys.farmSnapshot, farmId));
    if (raw == null || raw.isEmpty) return true;
    try {
      final farm = FarmModel.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final ok = await _pushFarm(farm);
      if (ok) {
        await _settingsDao.set(dirtyKey, '0');
      }
      return ok;
    } catch (_) {
      return false;
    }
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
