import 'dart:async';
import 'package:domain/domain.dart';
import '../repositories/sync_repository.dart';
import 'connectivity_service.dart';

/// محرك المزامنة
///
/// الآلية:
/// 1. مراقبة حالة الاتصال
/// 2. عند توفر الإنترنت → رفع السجلات المعلقة كل 5 ثوانٍ
/// 3. حل التعارض: السجل الأحدث يفوز (Last Write Wins)
/// 4. تحديث sync_status لكل سجل
class SyncEngine {
  final MobileSyncRepository repository;
  final ConnectivityService connectivity;

  StreamSubscription<bool>? _connectivitySubscription;
  Timer? _syncTimer;
  bool _isSyncing = false;

  /// معرّف المزرعة — يُضبط بعد تسجيل الدخول لتفعيل السحب
  String? farmId;
  DateTime? _lastPull;

  SyncEngine({
    required this.repository,
    required this.connectivity,
  });

  /// بدء المحرك
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

  /// بدء المزامنة الدورية
  void _startPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _syncOnce(),
    );
  }

  /// إيقاف المزامنة الدورية
  void _stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  /// مزامنة واردة: سحب سجلات الأجهزة الأخرى (كل 30 ثانية كحد أدنى)
  Future<void> _pullOnce() async {
    final fid = farmId;
    if (fid == null) return;

    final last = _lastPull;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastPull = DateTime.now();

    try {
      await repository.pullRemoteRecords(fid);
    } catch (_) {
      // لا اتصال أو خطأ مؤقت — المحاولة القادمة
    }
  }

  /// تنفيذ مزامنة واحدة
  Future<void> _syncOnce() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      await _pullOnce();

      final pendingCount = await repository.getPendingCount();
      if (pendingCount == 0) {
        _isSyncing = false;
        return;
      }

      final records = await repository.getPendingRecords(limit: 50);

      final result = await repository.uploadBatch(records);

      for (final record in records) {
        if (result.successIds.contains(record.id)) {
          await repository.markAsSynced(record.id!);
        } else if (result.isConflict(record.id!)) {
          await _resolveConflict(record);
        } else {
          await repository.incrementAttempts(record.id!);
        }
      }
    } catch (e) {
      await repository.logError('Sync failed: $e');
    } finally {
      _isSyncing = false;
    }
  }

  /// حل التعارض - السجل الأحدث يفوز
  Future<void> _resolveConflict(SyncRecord record) async {
    try {
      final remoteRecord = await repository.getRemoteRecord(
        record.tableName,
        record.recordId,
      );

      if (remoteRecord != null && record.updatedAt.isAfter(remoteUpdatedAt(remoteRecord))) {
        await repository.forceUpload(record);
        await repository.markAsSynced(record.id!);
      } else if (remoteRecord != null) {
        await repository.replaceLocalWithRemote(record, remoteRecord);
        await repository.markAsSynced(record.id!);
      }
    } catch (e) {
      await repository.markAsFailed(record.id!, e.toString());
    }
  }

  /// استخراج وقت التحديث من السجل السحابي
  DateTime remoteUpdatedAt(Map<String, dynamic> remote) {
    final value = remote['updated_at'] ?? remote['created_at'];
    if (value == null) return DateTime.now();
    return DateTime.tryParse(value.toString()) ?? DateTime.now();
  }

  /// مزامنة يدوية
  Future<void> syncNow() async {
    await _syncOnce();
  }

  /// إيقاف المحرك
  Future<void> stop() async {
    _syncTimer?.cancel();
    await _connectivitySubscription?.cancel();
  }
}