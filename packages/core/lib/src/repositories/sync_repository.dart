import 'package:core/src/models/sync_change_model.dart';

/// واجهة مستودع المزامنة المحسّنة (المرحلة 2)
/// تدعم الحقول الجديدة: status, operation, server_version
abstract class SyncRepository {
  /// جلب سجلات المزامنة المعلقة محلياً
  Future<List<SyncChangeModel>> getPendingChanges({int limit = 50});

  /// حفظ تغيير جديد في طابور المزامنة المحلية
  Future<void> queueChange(SyncChangeModel change);

  /// تحديث حالة السجلات بعد المزامنة الناجحة
  Future<void> markAsSynced(List<int> ids);

  /// تحديث حالة السجل كـ "فشل" مع رسالة الخطأ
  Future<void> markAsFailed(int id, String errorMessage);

  /// حذف السجلات القديمة المُزامَنة لتوفير المساحة
  Future<void> cleanupOldSyncedRecords({int daysToKeep = 30});

  /// الحصول على عدد السجلات المعلقة
  Future<int> getPendingCount();

  /// الحصول على عدد السجلات الفاشلة
  Future<int> getFailedCount();

  /// الحصول على عدد السجلات المتضاربة
  Future<int> getConflictCount();

  /// مسح جميع السجلات المعلقة (للاستخدام في حالات الطوارئ)
  Future<void> clearAllPending();

  /// رفع مجموعة سجلات إلى السحابة
  Future<BatchSyncResult> uploadBatch(List<SyncChangeModel> records);

  /// سحب السجلات البعيدة إلى القاعدة المحلية
  Future<int> pullRemoteRecords(String farmId);

  /// دورة مزامنة كاملة
  Future<FullSyncResult> syncNow(String farmId);
}

/// نتيجة المزامنة الدفعية
class BatchSyncResult {
  final List<int> successIds;
  final List<int> failedIds;
  final List<int> conflictIds;
  final String? errorMessage;

  BatchSyncResult({
    required this.successIds,
    required this.failedIds,
    this.conflictIds = const [],
    this.errorMessage,
  });

  int get successCount => successIds.length;
  int get failedCount => failedIds.length + conflictIds.length;
  bool get hasFailures => failedIds.isNotEmpty || conflictIds.isNotEmpty;
}

/// نتيجة المزامنة الكاملة
class FullSyncResult {
  final int uploadedCount;
  final int downloadedCount;
  final int failedCount;
  final DateTime completedAt;
  final String? errorMessage;

  FullSyncResult({
    required this.uploadedCount,
    required this.downloadedCount,
    required this.failedCount,
    required this.completedAt,
    this.errorMessage,
  });

  bool get isSuccess => failedCount == 0;
}
