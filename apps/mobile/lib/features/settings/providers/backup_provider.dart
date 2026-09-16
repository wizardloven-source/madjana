import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:data/data.dart';

/// خدمة النسخ الاحتياطي — مثيل واحد مشترك
final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService();
});

/// حالة النسخ الاحتياطي
class BackupState {
  final bool isBackingUp;
  final bool isRestoring;
  final BackupResult? lastBackup;
  final RestoreResult? lastRestore;
  final String? errorMessage;
  final List<BackupMetadata> backups;
  final bool isLoading;

  const BackupState({
    this.isBackingUp = false,
    this.isRestoring = false,
    this.lastBackup,
    this.lastRestore,
    this.errorMessage,
    this.backups = const [],
    this.isLoading = false,
  });

  BackupState copyWith({
    bool? isBackingUp,
    bool? isRestoring,
    BackupResult? lastBackup,
    RestoreResult? lastRestore,
    bool clearRestore = false,
    String? errorMessage,
    bool clearError = false,
    List<BackupMetadata>? backups,
    bool? isLoading,
  }) =>
      BackupState(
        isBackingUp: isBackingUp ?? this.isBackingUp,
        isRestoring: isRestoring ?? this.isRestoring,
        lastBackup: lastBackup ?? this.lastBackup,
        lastRestore: clearRestore ? null : (lastRestore ?? this.lastRestore),
        errorMessage:
            clearError ? null : (errorMessage ?? this.errorMessage),
        backups: backups ?? this.backups,
        isLoading: isLoading ?? this.isLoading,
      );
}

/// مزوّد النسخ الاحتياطي
class BackupNotifier extends StateNotifier<BackupState> {
  final BackupService _service;

  BackupNotifier(this._service) : super(const BackupState());

  /// تحميل قائمة النسخ
  Future<void> loadBackups() async {
    state = state.copyWith(isLoading: true);
    try {
      final backups = await _service.listBackups();
      state = state.copyWith(backups: backups, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'تعذّر تحميل النسخ الاحتياطية: $e',
      );
    }
  }

  /// إنشاء نسخة احتياطية
  Future<BackupResult> createBackup() async {
    state = state.copyWith(isBackingUp: true, clearError: true);
    final result = await _service.createBackup();
    state = state.copyWith(
      isBackingUp: false,
      clearRestore: true,
      errorMessage: result.success ? null : result.errorMessage,
    );
    await loadBackups();
    return result;
  }

  /// استعادة نسخة احتياطية
  Future<RestoreResult> restoreBackup(String backupId) async {
    state = state.copyWith(isRestoring: true, clearError: true);
    final result = await _service.restoreBackup(backupId);
    state = state.copyWith(
      isRestoring: false,
      lastRestore: result,
      errorMessage: result.success ? null : result.errorMessage,
    );
    await loadBackups();
    return result;
  }

  /// حذف نسخة احتياطية
  Future<void> deleteBackup(String backupId) async {
    await _service.deleteBackup(backupId);
    await loadBackups();
  }

  /// مسح جميع النسخ
  Future<void> clearAll() async {
    await _service.clearAllBackups();
    await loadBackups();
  }
}

final backupProvider =
    StateNotifierProvider<BackupNotifier, BackupState>((ref) {
  final service = ref.watch(backupServiceProvider);
  return BackupNotifier(service);
});