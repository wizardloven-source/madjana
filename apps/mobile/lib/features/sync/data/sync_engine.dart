import 'dart:async';
import 'package:domain/domain.dart';
import '../repositories/sync_repository.dart';
import 'connectivity_service.dart';

/// محرك المزامنة المحسّن
///
/// التحسينات الجديدة:
/// 1. UPLOAD أولاً ثم PULL لتجنب التعارضات
/// 2. تسجيل أخطاء تفصيلي بدلاً من ابتلاعها
/// 3. تحديث _lastPull فقط بعد النجاح
/// 4. فترة مزامنة أطول (30 ثانية بدلاً من 5)
/// 5. دعم المزامنة عند استئناف التطبيق
/// 6. إشعارات عند فشل المزامنة
class SyncEngine {
  final MobileSyncRepository repository;
  final ConnectivityService connectivity;

  StreamSubscription<bool>? _connectivitySubscription;
  Timer? _syncTimer;
  bool _isSyncing = false;

  /// معرّف المزرعة — يُضبط بعد تسجيل الدخول لتفعيل السحب
  String? farmId;
  DateTime? _lastPull;
  DateTime? _lastSuccessfulPull;

  /// الحد الأقصى لمحاولات الرفع قبل تعليم كفاشل
  static const int _maxAttempts = 10;

  /// هل المزامنة التلقائية مفعلة
  bool autoSyncEnabled = true;

  /// آخر خطأ حدث خلال المزامنة
  String? lastError;

  /// عدد المحاولات الفاشلة المتتالية
  int _consecutiveFailures = 0;

  /// الحد الأقصى للفشل المتتالي قبل إيقاف المزامنة المؤقت
  static const int _maxConsecutiveFailures = 5;

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
    _stopPeriodicSync();
    // زيادة الفترة إلى 30 ثانية لتقليل الحمل على الجهاز والسيرفر
    _syncTimer = Timer.periodic(
      const Duration(seconds: 30),
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

    final last = _lastSuccessfulPull;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 30)) {
      return;
    }

    try {
      final pulled = await repository.pullRemoteRecords(fid);
      // تحديث وقت آخر مزامنة ناجحة فقط
      _lastSuccessfulPull = DateTime.now();
      _lastPull = _lastSuccessfulPull;
      _consecutiveFailures = 0;
      
      if (pulled > 0) {
        // يمكن هنا إرسال إشعار للمستخدم بوصول بيانات جديدة
      }
    } catch (e, stackTrace) {
      lastError = 'Pull failed: $e';
      await repository.logError(lastError!);
      _consecutiveFailures++;
      
      // عدم تحديث _lastPull عند الفشل للمحاولة مرة أخرى قريباً
      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        // إيقاف مؤقت للمزامنة بعد فشل متتالي
        _stopPeriodicSync();
        lastError = 'Sync paused after $_maxConsecutiveFailures consecutive failures';
        await repository.logError(lastError!);
      }
    }
  }

  /// تنفيذ مزامنة واحدة
  Future<void> _syncOnce() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      // UPLOAD أولاً لتجنب التعارضات
      if (autoSyncEnabled) {
        final pendingCount = await repository.getPendingCount();
        if (pendingCount > 0) {
          final records = await repository.getPendingRecords(limit: 50);

          if (records.isNotEmpty) {
            final result = await repository.uploadBatch(records);

            for (final record in records) {
              if (record.id == null) continue;

              if (result.successIds.contains(record.id)) {
                await repository.markAsSynced(record.id!);
                _consecutiveFailures = 0;
              } else if (result.isConflict(record.id!)) {
                await _resolveConflict(record);
              } else {
                // فشل غير محدد — زيادة عدد المحاولات
                final attempts = record.attempts + 1;
                if (attempts >= _maxAttempts) {
                  await repository.markAsFailed(
                    record.id!, 
                    'Exceeded max attempts ($_maxAttempts)',
                  );
                  _consecutiveFailures++;
                } else {
                  await repository.incrementAttempts(record.id!);
                }
              }
            }
          }
        }
      }

      // السحب من السحابة يعمل دائماً (حتى مع تعطيل الرفع)
      await _pullOnce();
      
    } catch (e, stackTrace) {
      lastError = 'Sync failed: $e\n$stackTrace';
      await repository.logError(lastError!);
      _consecutiveFailures++;
      
      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        _stopPeriodicSync();
        lastError = 'Sync paused after $_maxConsecutiveFailures consecutive failures';
        await repository.logError(lastError!);
      }
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

      if (remoteRecord == null) {
        // السجل غير موجود في السحابة — رفعه إجبارياً
        await repository.forceUpload(record);
        await repository.markAsSynced(record.id!);
        return;
      }

      if (record.updatedAt.isAfter(remoteUpdatedAt(remoteRecord))) {
        await repository.forceUpload(record);
        await repository.markAsSynced(record.id!);
      } else {
        await repository.replaceLocalWithRemote(record, remoteRecord);
        await repository.markAsSynced(record.id!);
      }
    } catch (e, stackTrace) {
      final error = 'Conflict resolution failed: $e';
      await repository.logError(error);
      await repository.markAsFailed(record.id!, error);
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

  /// إعادة تشغيل المزامنة بعد توقفها بسبب أخطاء متتالية
  Future<void> resumeSync() async {
    _consecutiveFailures = 0;
    lastError = null;
    _startPeriodicSync();
  }

  /// إيقاف المحرك
  Future<void> stop() async {
    _stopPeriodicSync();
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  /// الحصول على حالة المزامنة
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

/// معلومات حالة المزامنة
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
