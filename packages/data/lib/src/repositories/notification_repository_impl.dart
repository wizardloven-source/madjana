import 'package:core/core.dart';
import '../datasources/remote/supabase_notification_datasource.dart';

/// تنفيذ مستودع الإشعارات
class NotificationRepositoryImpl implements NotificationRepository {
  final SupabaseNotificationDatasource _remoteDatasource;

  NotificationRepositoryImpl({
    required SupabaseNotificationDatasource remoteDatasource,
  }) : _remoteDatasource = remoteDatasource;

  @override
  Future<List<AppNotificationModel>> getActiveNotifications(String farmId) async {
    try {
      return await _remoteDatasource.getActiveNotifications(farmId)
          .timeout(const Duration(seconds: 8), onTimeout: () => <AppNotificationModel>[]);
    } catch (_) {
      return <AppNotificationModel>[];
    }
  }

  @override
  Future<List<AppNotificationModel>> getAllNotifications(String farmId) async {
    try {
      return await _remoteDatasource.getNotifications(farmId)
          .timeout(const Duration(seconds: 8), onTimeout: () => <AppNotificationModel>[]);
    } catch (_) {
      return <AppNotificationModel>[];
    }
  }

  @override
  Future<void> sendNotification(AppNotificationModel notification) async {
    try {
      await _remoteDatasource.createNotification(notification)
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  @override
  Future<void> deleteNotification(String id) async {
    try {
      await _remoteDatasource.deleteNotification(id)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  @override
  Future<void> toggleNotification(String id, bool isActive) async {
    try {
      await _remoteDatasource.toggleActive(id, isActive)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }
}
