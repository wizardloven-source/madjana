import 'package:core/src/models/sync_change_model.dart';

/// واجهة مستودع المزامنة المحسّنة (المرحلة 2)
/// تدعم الحقول الجديدة: status, operation, server_version
abstract class SyncRepository {
  /// جلب سجلات المزامنة المعلقة محلياً
  Future<List<SyncChangeModel>> getPendingChanges({int limit = 50});

  /// حفظ تغيير جديد في طابور المزامنة المحلية
  Future<void> queueChange(SyncChangeModel change);

  /// تحديث حالة السجلات بعد المزامنة الناجحة
  Future<void> markAsSynced(List<String> ids);

  /// تحديث حالة السجل كـ "فشل" مع رسالة الخطأ
  Future<void> markAsFailed(String id, String errorMessage);

  /// تحديث حالة السجل كـ "صراع" (يحتاج مراجعة يدوية)
  Future<void> markAsConflict(String id);

  /// حذف السجلات القديمة المُزامَنة لتوفير المساحة
  Future<void> cleanupOldSyncedRecords({int daysToKeep = 30});

  /// الحصول على عدد السجلات المعلقة
  Future<int> getPendingCount();

  /// الحصول على عدد السجلات الفاشلة
  Future<int> getFailedCount();

  /// الحصول على عدد السجلات المزامَنة بنجاح
  Future<int> getSyncedCount();

  /// جلب سجل عمليات المزامنة الأخيرة (لسجل مركز المزامنة)
  Future<List<SyncHistoryEntry>> getSyncHistory({int limit = 20});

  /// الحصول على عدد السجلات المتضاربة
  Future<int> getConflictCount();

  /// مسح جميع السجلات المعلقة (للاستخدام في حالات الطوارئ)
  Future<void> clearAllPending();

  /// رفع مجموعة سجلات إلى السحابة
  Future<BatchSyncResult> uploadBatch(List<SyncChangeModel> records);

  /// سحب السجلات البعيدة إلى القاعدة المحلية + دمجها
  Future<PullResult> pullAndMerge(String farmId);

  /// دورة مزامنة كاملة (رفع → سحب → دمج)
  Future<FullSyncResult> syncNow(String farmId);
}

/// نتيجة المزامنة الدفعية
class BatchSyncResult {
  final List<String> successIds;
  final List<String> failedIds;
  final List<String> conflictIds;
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
  final bool resyncRequired;
  final String? errorMessage;

  FullSyncResult({
    required this.uploadedCount,
    required this.downloadedCount,
    required this.failedCount,
    required this.completedAt,
    this.resyncRequired = false,
    this.errorMessage,
  });

  bool get isSuccess => failedCount == 0;
}

/// نتيجة السحب من الخادم
class PullResult {
  final int downloadedCount;
  final int appliedCount;
  final int conflictCount;
  final int latestVersion;
  final bool resyncRequired;
  final String? errorMessage;

  const PullResult({
    this.downloadedCount = 0,
    this.appliedCount = 0,
    this.conflictCount = 0,
    this.latestVersion = 0,
    this.resyncRequired = false,
    this.errorMessage,
  });
}

/// إدخال في سجل عمليات المزامنة (مركز المزامنة)
class SyncHistoryEntry {
  final String id;
  final DateTime createdAt;
  final int uploaded;
  final int downloaded;
  final int failed;
  final List<String> erroredTables;
  final String? errorMessage;

  const SyncHistoryEntry({
    required this.id,
    required this.createdAt,
    required this.uploaded,
    required this.downloaded,
    required this.failed,
    this.erroredTables = const [],
    this.errorMessage,
  });

  factory SyncHistoryEntry.fromMap(Map<String, dynamic> map) {
    return SyncHistoryEntry(
      id: map['id'] as String,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
      uploaded: (map['uploaded'] as num?)?.toInt() ?? 0,
      downloaded: (map['downloaded'] as num?)?.toInt() ?? 0,
      failed: (map['failed'] as num?)?.toInt() ?? 0,
      erroredTables: ((map['errored_tables'] as String?) ?? '')
          .split(',')
          .where((e) => e.isNotEmpty)
          .toList(),
      errorMessage: map['error_message'] as String?,
    );
  }
}
