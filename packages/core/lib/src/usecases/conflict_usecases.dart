import 'package:core/core.dart';

/// حالة استخدام لحل تعارضات المزامنة يدوياً
class ResolveConflictUseCase {
  final ConflictRepository _conflictRepo;
  final SyncRepository _syncRepo;

  ResolveConflictUseCase(this._conflictRepo, this._syncRepo);

  /// حل تعارض محدد
  /// [resolution] يمكن أن تكون: 'client_wins', 'server_wins', 'merge', 'ignore'
  Future<void> execute(String conflictId, String resolution) async {
    final conflict = await _conflictRepo.getConflictById(conflictId);
    
    if (conflict == null) {
      throw Exception('Conflict not found');
    }

    switch (resolution) {
      case 'client_wins':
        // إعادة إرسال بيانات العميل إلى السيرفر
        await _retrySync(conflict);
        await _conflictRepo.resolveConflict(conflictId, resolution: resolution);
        break;
        
      case 'server_wins':
        // تحديث البيانات المحلية ببيانات السيرفر
        await _applyServerData(conflict);
        await _conflictRepo.resolveConflict(conflictId, resolution: resolution);
        break;
        
      case 'merge':
        // دمج البيانات (يتطلب تدخلاً يدوياً من المستخدم)
        throw Exception('Manual merge not implemented yet. Use client_wins or server_wins.');
        
      case 'ignore':
        await _conflictRepo.ignoreConflict(conflictId);
        break;
        
      default:
        throw Exception('Invalid resolution type: $resolution');
    }
  }

  Future<void> _retrySync(ConflictModel conflict) async {
    // إعادة إنشاء سجل مزامنة جديد
    await _syncRepo.addChange(
      tableName: conflict.tableName,
      recordId: conflict.recordId,
      operation: 'UPDATE', // نعتبرها تحديث
      payload: conflict.clientData,
      farmId: conflict.clientData['farm_id'],
      userId: conflict.clientData['worker_id'] ?? conflict.clientData['created_by'],
    );
  }

  Future<void> _applyServerData(ConflictModel conflict) async {
    if (conflict.serverData == null) {
      throw Exception('No server data available to apply');
    }

    // إعادة إرسال بيانات السيرفر كـ upsert محلي
    await _syncRepo.addChange(
      tableName: conflict.tableName,
      recordId: conflict.recordId,
      operation: 'UPSERT',
      payload: conflict.serverData!,
      farmId: conflict.serverData!['farm_id'],
      userId: conflict.serverData!['worker_id'] ?? conflict.serverData!['created_by'],
    );
  }
}

/// حالة استخدام لجلب جميع التعارضات المعلقة
class GetConflictsUseCase {
  final ConflictRepository _conflictRepo;

  GetConflictsUseCase(this._conflictRepo);

  Future<List<ConflictModel>> execute({String? tableName}) async {
    return await _conflictRepo.getAllConflicts(
      tableName: tableName,
      status: 'pending',
    );
  }
}
