import 'package:core/core.dart';
import '../repositories/sync_repository.dart';

/// حالة استخدام: مزامنة البيانات مع السحابة
///
/// الآلية:
/// 1. جلب السجلات ذات sync_status = pending
/// 2. رفعها دفعة واحدة
/// 3. تحديث الحالة: synced | conflict | failed
/// 4. في حالة الفشل: إعادة المحاولة لاحقاً
class SyncDataUseCase {
  final SyncRepository repository;

  const SyncDataUseCase(this.repository);

  Future<SyncResult> call() async {
    try {
      final pendingRecords = await repository.getPendingChanges();

      if (pendingRecords.isEmpty) {
        return SyncResult.success(uploadedCount: 0);
      }

      final result = await repository.uploadBatch(pendingRecords);

      for (final record in pendingRecords) {
        if (result.successIds.contains(record.recordId)) {
          await repository.markAsSynced([record.recordId]);
        } else if (result.conflictIds.contains(record.recordId)) {
          await repository.markAsConflict(record.recordId);
        } else {
          await repository.markAsFailed(record.recordId, result.errorMessage ?? 'Unknown error');
        }
      }

      return SyncResult.success(
        uploadedCount: result.successIds.length,
        failedCount: result.failedCount - result.conflictIds.length,
        conflictCount: result.conflictIds.length,
      );
    } catch (e) {
      return SyncResult.failure('فشل المزامنة: $e');
    }
  }
}

class SyncResult {
  final bool success;
  final int uploadedCount;
  final int failedCount;
  final int conflictCount;
  final String? error;

  const SyncResult._({
    required this.success,
    this.uploadedCount = 0,
    this.failedCount = 0,
    this.conflictCount = 0,
    this.error,
  });

  factory SyncResult.success({
    int uploadedCount = 0,
    int failedCount = 0,
    int conflictCount = 0,
  }) {
    return SyncResult._(
      success: true,
      uploadedCount: uploadedCount,
      failedCount: failedCount,
      conflictCount: conflictCount,
    );
  }

  factory SyncResult.failure(String error) {
    return SyncResult._(success: false, error: error);
  }
}