import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:data/data.dart';
import 'providers.dart';

/// مفتاح تخزين مظهر الواجهة في إعدادات التطبيق المحلية
const String kThemeModeKey = 'ui_theme_mode';

/// نوع المظهر الحالي (ليلي افتراضياً)
final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>(
  (ref) => ThemeModeNotifier(ref.read(settingsDaoProvider)),
);

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  final SettingsDao _dao;

  ThemeModeNotifier(this._dao) : super(ThemeMode.dark) {
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await _dao.get(kThemeModeKey);
      if (raw != null && mounted) {
        state = raw == 'light' ? ThemeMode.light : ThemeMode.dark;
      }
    } catch (_) {}
  }

  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    try {
      await _dao.set(kThemeModeKey, mode == ThemeMode.light ? 'light' : 'dark');
    } catch (_) {}
  }
}