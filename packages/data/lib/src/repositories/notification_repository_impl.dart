import 'package:core/core.dart';
import 'package:flutter/foundation.dart' show debugPrint;
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
    } catch (e) {
      debugPrint('madjana: getActiveNotifications offline: $e');
      return <AppNotificationModel>[];
    }
  }

  @override
  Future<List<AppNotificationModel>> getAllNotifications(String farmId) async {
    try {
      return await _remoteDatasource.getNotifications(farmId)
          .timeout(const Duration(seconds: 8), onTimeout: () => <AppNotificationModel>[]);
    } catch (e) {
      debugPrint('madjana: getAllNotifications offline: $e');
      return <AppNotificationModel>[];
    }
  }

  @override
  Future<void> sendNotification(AppNotificationModel notification) async {
    try {
      await _remoteDatasource.createNotification(notification)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('madjana: sendNotification failed: $e');
    }
  }

  @override
  Future<void> deleteNotification(String id) async {
    try {
      await _remoteDatasource.deleteNotification(id)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('madjana: deleteNotification failed: $e');
    }
  }

  @override
  Future<void> toggleNotification(String id, bool isActive) async {
    try {
      await _remoteDatasource.toggleActive(id, isActive)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('madjana: toggleNotification failed: $e');
    }
  }
}
