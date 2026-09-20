import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/design_tokens.dart';
import 'package:data/data.dart';
import '../../../core/providers.dart';

/// الإشعارات النشطة من المدير (من السحابة)
/// [farmId] معرف المدجنة
/// عند انقطاع الإنترنت تُعرض آخر نسخة مُحمّلَة (كاش) بدل قائمة فارغة.
final Map<String, List<AppNotificationModel>> _activeNoticesCache = {};

final activeNoticesProvider =
    FutureProvider.autoDispose.family<List<AppNotificationModel>, String>(
        (ref, farmId) async {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    return _activeNoticesCache[farmId] ?? const <AppNotificationModel>[];
  }
  try {
    final rows = await client
        .from('app_notifications')
        .select()
        .eq('farm_id', farmId)
        .eq('is_active', true)
        .order('created_at', ascending: false);

    final notices = ((rows as List).cast<Map<String, dynamic>>())
        .map(AppNotificationModel.fromJson)
        .toList();
    _activeNoticesCache[farmId] = notices;
    return notices;
  } catch (_) {
    // Offline: نسخ من ذاكرة الجلسة الحالية، وإلا قائمة فارغة
    return _activeNoticesCache[farmId] ?? const <AppNotificationModel>[];
  }
});

/// حالة التذكيرات المحلية للعامل
class RemindersState {
  final List<ReminderModel> reminders;
  final bool isLoading;

  const RemindersState({this.reminders = const [], this.isLoading = false});
}

/// مدير التذكيرات الخاصة (محلي فقط — لا يُزامَن)
class RemindersNotifier extends StateNotifier<RemindersState> {
  final RemindersDao _dao;

  RemindersNotifier(this._dao) : super(const RemindersState()) {
    refresh();
  }

  Future<void> refresh() async {
    final items = await _dao.getAll();
    state = RemindersState(reminders: items);
  }

  Future<void> add({required String title, String? body}) async {
    await _dao.add(title: title, body: body);
    await refresh();
  }

  Future<void> delete(String id) async {
    await _dao.delete(id);
    await refresh();
  }
}

final remindersProvider =
    StateNotifierProvider<RemindersNotifier, RemindersState>((ref) {
  return RemindersNotifier(ref.watch(remindersDaoProvider));
});

/// لون حسب مستوى الإشعار
Color noticeColor(BuildContext context, String level) {
  switch (level) {
    case 'danger':
      return Theme.of(context).colorScheme.error;
    case 'warning':
      return AppColors.warning;
    default:
      return Theme.of(context).colorScheme.primary;
  }
}
