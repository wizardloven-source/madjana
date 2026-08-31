import 'package:core/core.dart';

/// واجهة مستودع التعارضات
abstract class ConflictRepository {
  Future<List<ConflictModel>> getAllConflicts({String? tableName, String? status});
  Future<void> resolveConflict(String conflictId, {required String resolution});
  Future<void> ignoreConflict(String conflictId);
  Future<void> addConflict(ConflictModel conflict);
  Future<ConflictModel?> getConflictById(String id);
}
