import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'package:data/data.dart';
import '../../../core/providers.dart';

/// الإشعارات النشطة من المدير (من السحابة)
/// [farmId] معرف المدجنة
final activeNoticesProvider =
    FutureProvider.autoDispose.family<List<AppNotificationModel>, String>(
        (ref, farmId) async {
  final client = ref.watch(supabaseClientProvider);
  try {
    final rows = await client
        .from('app_notifications')
        .select()
        .eq('farm_id', farmId)
        .eq('is_active', true)
        .order('created_at', ascending: false);

    return ((rows as List).cast<Map<String, dynamic>>())
        .map(AppNotificationModel.fromJson)
        .toList();
  } catch (_) {
    return const <AppNotificationModel>[];
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
      return Colors.orange.shade700;
    default:
      return Theme.of(context).colorScheme.primary;
  }
}
