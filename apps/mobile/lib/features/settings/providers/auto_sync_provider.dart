import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// إعدادات المزامنة التلقائية
class AutoSyncNotifier extends StateNotifier<bool> {
  static const String _key = 'auto_sync_enabled';

  AutoSyncNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_key);
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> toggle(bool enabled) async {
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
  }
}

final autoSyncProvider = StateNotifierProvider<AutoSyncNotifier, bool>((ref) {
  return AutoSyncNotifier();
});
