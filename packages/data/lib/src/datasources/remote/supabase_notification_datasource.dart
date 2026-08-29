import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات الإشعارات عبر Supabase
class SupabaseNotificationDatasource {
  final SupabaseClient _client;

  SupabaseNotificationDatasource(this._client);

  Future<List<AppNotificationModel>> getNotifications(String farmId) async {
    final data = await _client
        .from('app_notifications')
        .select()
        .eq('farm_id', farmId)
        .order('created_at', ascending: false);

    return (data as List)
        .map((e) => AppNotificationModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<List<AppNotificationModel>> getActiveNotifications(String farmId) async {
    final data = await _client
        .from('app_notifications')
        .select()
        .eq('farm_id', farmId)
        .eq('is_active', true)
        .order('created_at', ascending: false);

    return (data as List)
        .map((e) => AppNotificationModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> createNotification(AppNotificationModel notification) async {
    await _client.from('app_notifications').insert(notification.toJson());
  }

  Future<void> deleteNotification(String id) async {
    await _client.from('app_notifications').delete().eq('id', id);
  }

  Future<void> toggleActive(String id, bool isActive) async {
    await _client
        .from('app_notifications')
        .update({'is_active': isActive})
        .eq('id', id);
  }
}
