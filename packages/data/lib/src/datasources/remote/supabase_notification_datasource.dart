import 'package:core/core.dart';
import 'supabase_api.dart';

/// ظ…طµط¯ط± ط¨ظٹط§ظ†ط§طھ ط§ظ„ط¥ط´ط¹ط§ط±ط§طھ ط¹ط¨ط± Supabase
class SupabaseNotificationDatasource {
  final SupabaseApi _api;

  SupabaseNotificationDatasource(this._api);

  Future<List<AppNotificationModel>> getNotifications(String farmId) async {
    final data = await _api
        .from('app_notifications')
        .select()
        .eq('farm_id', farmId)
        .order('created_at', ascending: false)
        .get();

    return (data)
        .map((e) => AppNotificationModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<List<AppNotificationModel>> getActiveNotifications(String farmId) async {
    final data = await _api
        .from('app_notifications')
        .select()
        .eq('farm_id', farmId)
        .eq('is_active', true)
        .order('created_at', ascending: false)
        .get();

    return (data)
        .map((e) => AppNotificationModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> createNotification(AppNotificationModel notification) async {
    await _api.from('app_notifications').insert(notification.toJson()).run();
  }

  Future<void> deleteNotification(String id) async {
    await _api.from('app_notifications').delete().eq('id', id).run();
  }

  Future<void> toggleActive(String id, bool isActive) async {
    await _api
        .from('app_notifications')
        .update({'is_active': isActive})
        .eq('id', id)
        .run();
  }
}