import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../data/connectivity_service.dart';

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

/// Provider للمزامنة — يعتمد على محرك بيانات واحد (data.SyncRepository)
class SyncNotifier extends StateNotifier<SyncState> {
  final SyncRepository repository;
  final ConnectivityService connectivity;

  StreamSubscription<bool>? _connectivitySub;
  Timer? _syncTimer;
  String? _farmId;
  bool _isSyncing = false;
  int _consecutiveFailures = 0;
  static const int _maxConsecutiveFailures = 5;
  bool autoSyncEnabled = true;

  SyncNotifier({required this.repository, required this.connectivity})
      : super(const SyncState()) {
    _init();
  }

  Future<void> _init() async {
    await _refreshCounts();
    _watchConnectivity();
  }

  void setAutoSync(bool enabled) {
    autoSyncEnabled = enabled;
    if (!enabled) {
      _stopPeriodicSync();
    } else if (state.connectionStatus != SyncConnectionStatus.disconnected) {
      _startPeriodicSync();
    }
  }

  void _watchConnectivity() {
    _connectivitySub = connectivity.onConnectivityChanged.listen((connected) {
      state = state.copyWith(
        connectionStatus: connected
            ? SyncConnectionStatus.connected
            : SyncConnectionStatus.disconnected,
      );
      if (connected) {
        _refreshCounts();
        if (autoSyncEnabled) _startPeriodicSync();
      } else {
        _stopPeriodicSync();
      }
    });
  }

  void _startPeriodicSync() {
    _stopPeriodicSync();
    _syncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _syncOnce(),
    );
  }

  void _stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
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

  Future<void> _syncOnce() async {
    final fid = _farmId;
    if (fid == null || _isSyncing) return;
    _isSyncing = true;
    state = state.copyWith(isSyncing: true);
    try {
      await repository.syncNow(fid);
      _consecutiveFailures = 0;
      await _refreshCounts();
    } catch (_) {
      _consecutiveFailures++;
      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        _stopPeriodicSync();
      }
    } finally {
      _isSyncing = false;
      state = state.copyWith(isSyncing: false, lastSyncAt: DateTime.now());
    }
  }

  /// ضبط المزرعة بعد الدخول — يفعّل السحب من السحابة
  void setFarmId(String farmId) {
    final changed = _farmId != farmId;
    _farmId = farmId;
    if (changed) syncNow();
  }

  /// مزامنة يدوية
  Future<void> syncNow() async {
    await _syncOnce();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _stopPeriodicSync();
    super.dispose();
  }
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>((ref) {
  return SyncNotifier(
    repository: ref.watch(syncRepositoryProvider),
    connectivity: ref.watch(connectivityServiceProvider),
  );
});
