import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'package:data/data.dart';

/// Provider لإدارة حالة المزامنة وعرض السجلات المعلقة
final syncStatusProvider = StreamProvider.autoDispose<SyncStatus>((ref) {
  final syncRepo = ref.read(syncRepositoryProvider);
  // نفترض وجود stream يراقب حالة المزامنة
  // وإلا سنستخدم polling كل 5 ثواني
  return syncRepo.getSyncStatusStream();
});

/// Provider لجلب سجلات المزامنة المعلقة
final pendingSyncRecordsProvider = FutureProvider.autoDispose<List<SyncChangeModel>>((ref) async {
  final syncRepo = ref.read(syncRepositoryProvider);
  return await syncRepo.getPendingRecords();
});

/// Provider لتنفيذ المزامنة اليدوية
final manualSyncProvider = AsyncNotifierProvider<ManualSyncNotifier, bool>(() {
  return ManualSyncNotifier();
});

class ManualSyncNotifier extends AsyncNotifier<bool> {
  @override
  bool build() {
    return false;
  }

  Future<void> startSync() async {
    state = const AsyncValue.loading();
    try {
      final syncRepo = ref.read(syncRepositoryProvider);
      await syncRepo.syncPendingRecords();
      state = const AsyncValue.data(true);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}

/// نموذج حالة المزامنة
class SyncStatus {
  final int pendingCount;
  final int syncedCount;
  final int failedCount;
  final DateTime? lastSyncTime;
  final bool isSyncing;

  SyncStatus({
    required this.pendingCount,
    required this.syncedCount,
    required this.failedCount,
    this.lastSyncTime,
    this.isSyncing = false,
  });
}
