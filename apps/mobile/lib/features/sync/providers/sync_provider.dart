import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint, debugPrintStack;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../reference_data/providers/reference_data_provider.dart';
import '../data/connectivity_service.dart';

/// حالة المزامنة
class SyncState {
  final int pendingCount;
  final int syncedCount;
  final int failedCount;
  final bool isSyncing;
  final DateTime? lastSyncAt;
  final SyncConnectionStatus connectionStatus;

  /// نص آخر خطأсинcatch، لعرضه في شاشة المزامنة.
  ///
  /// كان `catch (_)` في _syncOnce يبتلع الاستثناء بالكامل: أي فشل شبكة أو
  /// RPC أو Edge Function 404 كان يختفي بلا أثر، فتظهر الواجهة كأن شيئاً لم
  /// يحدث ولا يمكن تشخيصه. هذه القيمة هي ما يجعل الخطأ مرئياً.
  final String? lastError;

  const SyncState({
    this.pendingCount = 0,
    this.syncedCount = 0,
    this.failedCount = 0,
    this.isSyncing = false,
    this.lastSyncAt,
    this.connectionStatus = SyncConnectionStatus.unknown,
    this.lastError,
  });

  SyncState copyWith({
    int? pendingCount,
    int? syncedCount,
    int? failedCount,
    bool? isSyncing,
    DateTime? lastSyncAt,
    SyncConnectionStatus? connectionStatus,
    String? lastError,
    bool clearError = false,
  }) {
    return SyncState(
      pendingCount: pendingCount ?? this.pendingCount,
      syncedCount: syncedCount ?? this.syncedCount,
      failedCount: failedCount ?? this.failedCount,
      isSyncing: isSyncing ?? this.isSyncing,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

enum SyncConnectionStatus { connected, disconnected, unknown }

/// Provider للمزامنة — يعتمد على محرك بيانات واحد (data.SyncRepository)
class SyncNotifier extends StateNotifier<SyncState> {
  final SyncRepository repository;
  final ConnectivityService connectivity;

  /// يُستدعى بعد كل مزامنة ناجحة لتحديث البيانات المرجعية المخزّنة مؤقتاً
  /// (إعدادات المدجنة مثل وزن الكيس، والزبائن) القادمة من سطح المكتب.
  final void Function()? onSynced;

  StreamSubscription<bool>? _connectivitySub;
  Timer? _syncTimer;
  Timer? _backoffTimer;
  String? _farmId;
  bool _isSyncing = false;
  int _consecutiveFailures = 0;
  int _backoffMinutes = 0;
  static const int _maxConsecutiveFailures = 5;
  static const int _maxBackoffMinutes = 30;
  bool autoSyncEnabled = true;

  SyncNotifier({
    required this.repository,
    required this.connectivity,
    this.onSynced,
  }) : super(const SyncState()) {
    _init();
  }

  Future<void> _init() async {
    // ترتيب مهم: نقرأ الإعداد أولاً لأن _probeConnectivity يبدأ المؤقت
    // شرطه autoSyncEnabled. كان يُقرأ بعد _watchConnectivity، فكان أول
    // فحص 연결 يتم بقيمة default قبل تحميل الإعداد المحفوظ.
    await _loadAutoSyncPref();
    await _refreshCounts();
    await _probeConnectivity();
    _watchConnectivity();
  }

  /// فحص الاتصال الابتدائي.
  ///
  /// `onConnectivityChanged` في connectivity_plus لا يُعيد الحالة الحالية
  /// عند الاشتراك، فلا إطلاق لهذا التدفق قبل أول تغيّر فعلي. النتيجة: عند
  /// فتح التطبيق على شبكة مستقرة لا يُطلق الحدث ولا يُشغَّل المؤقت ولا مرّة
  /// واحدة — ولا مزامنة تلقائية إطلاقاً. هذا الفحص يسدّ تلك الفجوة.
  Future<void> _probeConnectivity() async {
    try {
      final connected = await connectivity.isConnected();
      state = state.copyWith(
        connectionStatus: connected
            ? SyncConnectionStatus.connected
            : SyncConnectionStatus.disconnected,
      );
      if (connected && autoSyncEnabled) _startPeriodicSync();
    } catch (_) {
      // فحص فاشل = لا نعرف؛ نبقى على الحالة الافتراضية ولا نبدأ شيئاً.
    }
  }

  /// قراءة إعداد المزامنة التلقائية المحفوظ (المفتاح الذي يكتبه المحول
  /// في شاشة الإعدادات) — وإلا فالمفتاح لا أثر له على المحرك الفعلي.
  Future<void> _loadAutoSyncPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      autoSyncEnabled = prefs.getBool('auto_sync_enabled') ?? true;
    } catch (_) {}
  }

  /// يُستدعى عند تسجيل الخروج: يوقف المؤقتات الدورية (رفع كل 30 ثانية)
  /// وينظّف العدادات كي لا يستمر المحرك بالرفع لمدجنة سابقة تحت جلسة
  /// منتهية، ولا يظهر شعار أخطاء قديم على شاشة الدخول.
  void handleLoggedOut() {
    _stopPeriodicSync();
    _backoffTimer?.cancel();
    _farmId = null;
    _consecutiveFailures = 0;
    _backoffMinutes = 0;
    state = const SyncState();
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

  Future<FullSyncResult?> _syncOnce() async {
    final fid = _farmId;
    if (fid == null || _isSyncing) return null;
    _isSyncing = true;
    state = state.copyWith(isSyncing: true);
    try {
      final result = await repository.syncNow(fid);
      if (result.isSuccess) {
        _consecutiveFailures = 0;
        _backoffMinutes = 0;
        _backoffTimer?.cancel();
        // حدّث البيانات المرجعية المخزّنة مؤقتاً بعد نجاح السحب.
        try {
          onSynced?.call();
        } catch (_) {}
      }
      await _refreshCounts();
      // ═══ H-4 FIX: لا تُحدّث lastSyncAt إلا عند نجاح المزامنة الكاملة ═══
      state = state.copyWith(
        isSyncing: false,
        lastSyncAt: result.isSuccess ? DateTime.now() : null,
        clearError: result.isSuccess,
      );
      return result;
    } catch (e, st) {
      // كان يُبتلع هنا بلا تسجيل. سجّلاه: بدونهما يستحيل تحديد ما إذا كان
      // الفشل شبكةً أم RPC أم Edge Function غير منشورة.
      debugPrint('[sync] فشل: $e');
      debugPrintStack(stackTrace: st, maxFrames: 12);
      _consecutiveFailures++;
      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        _stopPeriodicSync();
        _scheduleBackoffRetry();
      }
      state = state.copyWith(isSyncing: false, lastError: _describe(e));
      return null;
    } finally {
      _isSyncing = false;
    }
  }

  /// تحويل الاستثناء إلى نص مقروء، مع تلميح لأشيع الأسباب.
  static String _describe(Object e) {
    final s = e.toString();
    final lower = s.toLowerCase();
    if (lower.contains('404') || lower.contains('function not found')) {
      return 'دالة المزامنة غير منشورة على الخادم (404) — '
          'sync_records تحتاج deploy من supabase/functions/sync_records';
    }
    if (lower.contains('failed host lookup') ||
        lower.contains('socketexception') ||
        lower.contains('connection')) {
      return 'تعذّر الوصول للسحابة — تحقق من الإنترنت';
    }
    if (lower.contains('jwt') || lower.contains('401')) {
      return 'انتهت الجلسة أو الرمز غير صالح — أعد تسجيل الدخول';
    }
    if (lower.contains('authorization_denied')) {
      return 'مرفوض من الخادم — صلاحيات غير كافية';
    }
    return s.length > 220 ? '${s.substring(0, 220)}…' : s;
  }

  /// ضبط المزرعة بعد الدخول — يفعّل السحب من السحابة
  void setFarmId(String farmId) {
    final changed = _farmId != farmId;
    _farmId = farmId;
    if (changed) syncNow();
    // لا يكفي الإرسال الواحد: بلا مؤقت دوري لا تُرفع الكتابة التالية.
    if (autoSyncEnabled &&
        state.connectionStatus != SyncConnectionStatus.disconnected) {
      _startPeriodicSync();
    }
  }

  /// رفع فوري بعد كتابة محلية (حفظ مخزون، إنتاج، دفعة…).
  ///
  /// الاعتماد على المؤقت وحده يترك السجل «في الانتظار» حتى 30 ثانية، وهو ما
  /// يقرأه العامل على أنه فشل. الاستدعاء بعد كل حفظ يزيل الغموض.
  Future<FullSyncResult?> syncAfterWrite() async {
    if (!autoSyncEnabled) return null;
    return _syncOnce();
  }

  /// مزامنة يدوية — تُعيد النتيجة الفعلية (null عند الفشل)
  Future<FullSyncResult?> syncNow() async {
    return _syncOnce();
  }

  /// جدولة إعادة مزامنة تلقائية بتأخير تصاعدي بعد فشل متكرر
  void _scheduleBackoffRetry() {
    _backoffTimer?.cancel();
    if (_backoffMinutes == 0) {
      _backoffMinutes = 2;
    } else {
      _backoffMinutes = (_backoffMinutes * 2).clamp(0, _maxBackoffMinutes);
    }
    _backoffTimer = Timer(Duration(minutes: _backoffMinutes), () {
      if (!autoSyncEnabled || _farmId == null) return;
      _consecutiveFailures = 0;
      _backoffMinutes = 0;
      if (state.connectionStatus != SyncConnectionStatus.disconnected) {
        _startPeriodicSync();
      }
    });
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _stopPeriodicSync();
    _backoffTimer?.cancel();
    super.dispose();
  }
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>((ref) {
  return SyncNotifier(
    repository: ref.watch(syncRepositoryProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    onSynced: () {
      // `farmSettingsProvider` الآن autoDispose ويجلب من الشبكة كل مرة، فـ
      // invalidate هنا يضمن أن أي تعديل أجراه المدير على سطح المكتب (مثل
      // وزن الكيس 24) يصل لشاشة الموبايل فور انتهاء المزامنة، بلا إعادة
      // تشغيل للتطبيق.
      ref.invalidate(farmSettingsProvider);
      ref.invalidate(customersProvider);
    },
  );
});
