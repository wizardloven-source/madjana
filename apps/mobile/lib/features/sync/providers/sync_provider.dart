import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers.dart';
import '../data/sync_repository_impl.dart';
import '../data/sync_engine.dart';

/// حالة المزامنة
class SyncState {
  final int pendingCount;
  final int syncedCount;
  final int failedCount;
  final bool isSyncing;
  final DateTime? lastSyncAt;
  final SyncConnectionStatus connectionStatus;

  const SyncState({
    this.pendingCount = 0,
    this.syncedCount = 0,
    this.failedCount = 0,
    this.isSyncing = false,
    this.lastSyncAt,
    this.connectionStatus = SyncConnectionStatus.unknown,
  });

  SyncState copyWith({
    int? pendingCount,
    int? syncedCount,
    int? failedCount,
    bool? isSyncing,
    DateTime? lastSyncAt,
    SyncConnectionStatus? connectionStatus,
  }) {
    return SyncState(
      pendingCount: pendingCount ?? this.pendingCount,
      syncedCount: syncedCount ?? this.syncedCount,
      failedCount: failedCount ?? this.failedCount,
      isSyncing: isSyncing ?? this.isSyncing,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      connectionStatus: connectionStatus ?? this.connectionStatus,
    );
  }
}

enum SyncConnectionStatus { connected, disconnected, unknown }

/// Provider للمزامنة
class SyncNotifier extends StateNotifier<SyncState> {
  final MobileSyncRepository repository;
  final SyncEngine engine;
  StreamSubscription<bool>? _connectivitySub;

  SyncNotifier({required this.repository, required this.engine})
      : super(const SyncState()) {
    _init();
  }

  Future<void> _init() async {
    await _refreshCounts();
    await engine.start();
    _watchConnectivity();
  }

  void setAutoSync(bool enabled) {
    engine.autoSyncEnabled = enabled;
  }

  void _watchConnectivity() {
    _connectivitySub = engine.connectivity.onConnectivityChanged.listen((connected) {
      state = state.copyWith(
        connectionStatus: connected
            ? SyncConnectionStatus.connected
            : SyncConnectionStatus.disconnected,
      );
      if (connected) {
        _refreshCounts();
      }
    });
  }

  Future<void> _refreshCounts() async {
    final pending = await repository.getPendingCount();
    final synced = await repository.getSyncedCount();
    final failed = await repository.getFailedCount();

    state = state.copyWith(
      pendingCount: pending,
      syncedCount: synced,
      failedCount: failed,
    );
  }

  /// ضبط المزرعة بعد الدخول — يفعّل السحب من السحابة
  void setFarmId(String farmId) {
    final changed = engine.farmId != farmId;
    engine.farmId = farmId;
    // اسحب فوراً عند أول ضبط أو تغيّر الحساب
    if (changed) engine.syncNow();
  }

  /// مزامنة يدوية
  Future<void> syncNow() async {
    state = state.copyWith(isSyncing: true);

    try {
      await engine.syncNow();
      await _refreshCounts();
      state = state.copyWith(
        isSyncing: false,
        lastSyncAt: DateTime.now(),
      );
    } catch (e) {
      state = state.copyWith(isSyncing: false);
    }
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    engine.stop();
    super.dispose();
  }
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>((ref) {
  final repository = ref.watch(mobileSyncRepositoryProvider);
  final engine = SyncEngine(
    repository: repository,
    connectivity: ref.watch(connectivityServiceProvider),
  );
  return SyncNotifier(repository: repository, engine: engine);
});
