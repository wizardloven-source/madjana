import '../models/notification_models.dart';

/// واجهة مستودع الإشعارات
abstract class NotificationRepository {
  /// جلب الإشعارات النشطة لمزرعة معينة
  Future<List<AppNotificationModel>> getActiveNotifications(String farmId);

  /// جلب كل الإشعارات لمزرعة معينة
  Future<List<AppNotificationModel>> getAllNotifications(String farmId);

  /// إرسال إشعار جديد
  Future<void> sendNotification(AppNotificationModel notification);

  /// حذف إشعار
  Future<void> deleteNotification(String id);

  /// تبديل حالة التنشيط
  Future<void> toggleNotification(String id, bool isActive);
}
