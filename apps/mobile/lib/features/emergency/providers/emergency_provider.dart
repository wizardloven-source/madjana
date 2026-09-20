import 'package:data/data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

/// نتيجة محاولة إرسال تنبيه الطوارئ
enum EmergencySubmitOutcome {
  /// أُرسل مباشرة (متصل)
  sent,

  /// حُفظ محلياً وسيُرسل تلقائياً عند عودة الاتصال
  queued,

  /// لا توجد مزرعة مرتبطة بالحساب
  missingFarm,
}

class EmergencySubmitResult {
  final EmergencySubmitOutcome outcome;
  final String? error;

  const EmergencySubmitResult(this.outcome, [this.error]);

  bool get sent => outcome == EmergencySubmitOutcome.sent;
  bool get queued => outcome == EmergencySubmitOutcome.queued;
  bool get failed => outcome == EmergencySubmitOutcome.missingFarm;
}

class EmergencyState {
  final int pendingCount;
  final int lastSentCount;

  const EmergencyState({this.pendingCount = 0, this.lastSentCount = 0});

  EmergencyState copyWith({int? pendingCount, int? lastSentCount}) {
    return EmergencyState(
      pendingCount: pendingCount ?? this.pendingCount,
      lastSentCount: lastSentCount ?? this.lastSentCount,
    );
  }
}

/// مدير تنبيهات الطوارئ — offline-first
/// - متصل: يكتب مباشرة إلى app_notifications بالسحابة
/// - غير متصل: يحفظ محلياً ثم يعيد المحاولة عند عودة الاتصال
class EmergencyNotifier extends StateNotifier<EmergencyState> {
  final Ref ref;
  final EmergencyAlertDao dao;

  EmergencyNotifier(this.ref, this.dao) : super(const EmergencyState()) {
    _init();
  }

  Future<void> _init() async {
    try {
      await dao.pruneSent();
    } catch (_) {}
    await _refreshPending();
  }

  Future<void> _refreshPending() async {
    final pending = await dao.pendingCount();
    state = state.copyWith(pendingCount: pending);
  }

  /// إرسال تنبيه — إن فشل (غير متصل) يُحفظ محلياً
  Future<EmergencySubmitResult> submit({
    required String alertType,
    String? description,
  }) async {
    final supabase = ref.read(supabaseClientProvider);
    final user = ref.read(authProvider).currentUser;
    final farmId = user?.farmId ?? '';
    final createdBy = user?.uid;

    if (farmId.isEmpty) {
      return const EmergencySubmitResult(
        EmergencySubmitOutcome.missingFarm,
        'لا توجد مزرعة مرتبطة بالحساب',
      );
    }

    final title = '🚨 طارئ: $alertType';
    final body = (description == null || description.trim().isEmpty)
        ? 'تنبيه طارئ من عامل — $alertType'
        : description.trim();

    try {
      final client = supabase;
      if (client == null) throw Exception('غير متصل');
      await client.from('app_notifications').insert({
        'farm_id': farmId,
        'title': title,
        'body': body,
        'level': 'danger',
        'is_persistent': true,
        'is_active': true,
        'created_by': createdBy,
      });
      return const EmergencySubmitResult(EmergencySubmitOutcome.sent);
    } catch (_) {
      // Offline/فشل: الحفظ محلياً وإعادة المحاولة لاحقاً
      try {
        await dao.add(
          farmId: farmId,
          alertType: alertType,
          description: body,
          createdBy: createdBy,
        );
        await _refreshPending();
      } catch (_) {}
      return const EmergencySubmitResult(EmergencySubmitOutcome.queued);
    }
  }

  /// إعادة محاولة إرسال التنبيهات المحلية المعلقة.
  /// تُرجع عدد التنبيهات ما زالت قيد الانتظار (0 = تم تسليم الكل).
  Future<int> retryPending() async {
    final supabase = ref.read(supabaseClientProvider);
    if (supabase == null) {
      await _refreshPending();
      return state.pendingCount;
    }

    var sent = 0;
    try {
      final pending = await dao.getPending();
      for (final record in pending) {
        try {
          await supabase.from('app_notifications').insert({
            'farm_id': record.farmId,
            'title': '🚨 طارئ: ${record.alertType}',
            'body': record.description ??
                'تنبيه طارئ من عامل — ${record.alertType}',
            'level': 'danger',
            'is_persistent': true,
            'is_active': true,
            'created_by': record.createdBy,
          });
          await dao.markSent(record.id);
          sent++;
        } catch (_) {
          // لا تزال غير متصل — نوقف ونعيد المحاولة لاحقاً
          break;
        }
      }
    } catch (_) {}

    await _refreshPending();
    state = state.copyWith(lastSentCount: state.lastSentCount + sent);
    return state.pendingCount;
  }
}

final emergencyProvider =
    StateNotifierProvider<EmergencyNotifier, EmergencyState>((ref) {
  return EmergencyNotifier(ref, ref.watch(emergencyAlertDaoProvider));
});