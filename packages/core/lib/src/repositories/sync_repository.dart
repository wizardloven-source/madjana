/// سجل طابور المزامنة
class SyncRecord {
  final String? id;
  final String tableName;
  final String recordId;
  final Map<String, dynamic> payload;
  final DateTime updatedAt;
  final int attempts;

  const SyncRecord({
    this.id,
    required this.tableName,
    required this.recordId,
    required this.payload,
    required this.updatedAt,
    this.attempts = 0,
  });

  SyncRecord copyWith({int? attempts, String? id}) {
    return SyncRecord(
      id: id ?? this.id,
      tableName: tableName,
      recordId: recordId,
      payload: payload,
      updatedAt: updatedAt,
      attempts: attempts ?? this.attempts,
    );
  }
}

/// نتيجة الرفع الجماعي
class BatchUploadResult {
  final List<String> successIds;
  final List<String> failedIds;
  final String? errorMessage;

  BatchUploadResult({
    required this.successIds,
    required this.failedIds,
    this.errorMessage,
  });

  int get failedCount => failedIds.length;
  bool isConflict(String id) => failedIds.contains(id);
}

/// واجهة مستودع المزامنة
abstract class SyncRepository {
  /// جلب السجلات المعلقة من كل الجداول
  Future<List<SyncRecord>> getPendingRecords({int limit = 50});

  /// عدد السجلات المعلقة
  Future<int> getPendingCount();

  /// عدد السجلات المزامنة
  Future<int> getSyncedCount();

  /// عدد السجلات الفاشلة
  Future<int> getFailedCount();

  /// رفع مجموعة سجلات
  Future<BatchUploadResult> uploadBatch(List<SyncRecord> records);

  /// سحب السجلات البعيدة إلى القاعدة المحلية (مزامنة واردة)
  ///
  /// يُرجع عدد السجلات المسحوبة/المحدّثة.
  Future<int> pullRemoteRecords(String farmId);

  /// تعليم سجل كمزامن
  Future<void> markAsSynced(String id);

  /// تعليم سجل كفاشل
  Future<void> markAsFailed(String id, String? error);

  /// زيادة عدد المحاولات
  Future<void> incrementAttempts(String id);

  /// جلب سجل من السحابة
  Future<Map<String, dynamic>?> getRemoteRecord(String table, String id);

  /// استبدال السجل المحلي بالسحابي
  Future<void> replaceLocalWithRemote(SyncRecord local, Map<String, dynamic> remote);

  /// رفع إجباري
  Future<void> forceUpload(SyncRecord record);

  /// تسجيل خطأ
  Future<void> logError(String error);
}