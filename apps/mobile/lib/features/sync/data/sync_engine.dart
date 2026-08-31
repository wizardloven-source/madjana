import 'dart:async';
import 'package:core/core.dart';
import '../repositories/sync_repository.dart';
import 'connectivity_service.dart';

/// محرك المزامنة المحسّن
class SyncEngine {
  final MobileSyncRepository repository;
  final ConnectivityService connectivity;

  StreamSubscription<bool>? _connectivitySubscription;
  Timer? _syncTimer;
  bool _isSyncing = false;

  String? farmId;
  DateTime? _lastPull;
  DateTime? _lastSuccessfulPull;

  static const int _maxAttempts = 10;
  bool autoSyncEnabled = true;
  String? lastError;
  int _consecutiveFailures = 0;
  static const int _maxConsecutiveFailures = 5;

  SyncEngine({
    required this.repository,
    required this.connectivity,
  });

  Future<void> start() async {
    _connectivitySubscription = connectivity.onConnectivityChanged.listen(
      (isConnected) {
        if (isConnected) {
          _startPeriodicSync();
        } else {
          _stopPeriodicSync();
        }
      },
    );

    final isConnected = await connectivity.isConnected();
    if (isConnected) {
      _startPeriodicSync();
    }
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

  Future<void> _pullOnce() async {
    final fid = farmId;
    if (fid == null) return;

    final last = _lastSuccessfulPull;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 30)) {
      return;
    }

    try {
      final pulled = await repository.pullRemoteRecords(fid);
      _lastSuccessfulPull = DateTime.now();
      _lastPull = _lastSuccessfulPull;
      _consecutiveFailures = 0;
    } catch (e) {
      lastError = 'Pull failed: $e';
      _consecutiveFailures++;

      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        _stopPeriodicSync();
        lastError = 'Sync paused after $_maxConsecutiveFailures consecutive failures';
      }
    }
  }

  Future<void> _syncOnce() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      if (autoSyncEnabled) {
        final pendingCount = await repository.getPendingCount();
        if (pendingCount > 0) {
          final records = await repository.getPendingRecords(limit: 50);

          if (records.isNotEmpty) {
            final result = await repository.uploadBatch(records);

            for (final record in records) {
              if (record.id == null) continue;

              if (result.successIds.contains(record.id)) {
                await repository.markAsSyncedById(record.tableName, record.recordId);
                _consecutiveFailures = 0;
              } else {
                await repository.markAsFailedById(
                  record.tableName,
                  record.recordId,
                  'Upload failed',
                );
                _consecutiveFailures++;
              }
            }
          }
        }
      }

      await _pullOnce();

    } catch (e) {
      lastError = 'Sync failed: $e';
      _consecutiveFailures++;

      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        _stopPeriodicSync();
        lastError = 'Sync paused after $_maxConsecutiveFailures consecutive failures';
      }
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> syncNow() async {
    await _syncOnce();
  }

  Future<void> resumeSync() async {
    _consecutiveFailures = 0;
    lastError = null;
    _startPeriodicSync();
  }

  Future<void> stop() async {
    _stopPeriodicSync();
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  SyncStatusInfo getStatusInfo() {
    return SyncStatusInfo(
      isSyncing: _isSyncing,
      lastPull: _lastPull,
      lastSuccessfulPull: _lastSuccessfulPull,
      consecutiveFailures: _consecutiveFailures,
      lastError: lastError,
      autoSyncEnabled: autoSyncEnabled,
    );
  }
}

class SyncStatusInfo {
  final bool isSyncing;
  final DateTime? lastPull;
  final DateTime? lastSuccessfulPull;
  final int consecutiveFailures;
  final String? lastError;
  final bool autoSyncEnabled;

  SyncStatusInfo({
    required this.isSyncing,
    this.lastPull,
    this.lastSuccessfulPull,
    required this.consecutiveFailures,
    this.lastError,
    required this.autoSyncEnabled,
  });

  bool get hasError => lastError != null;
  bool get isPaused => consecutiveFailures >= SyncEngine._maxConsecutiveFailures;
}
