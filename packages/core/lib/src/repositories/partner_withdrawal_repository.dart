import '../models/partner_summary.dart';
import '../models/partner_withdrawal.dart';

/// سحوبات الشركاء وملخّصهم (W7.4) — مبنية على جداول M23 ودوال M24 وRLS.
///
/// القراءة والكتابة تتمان مباشرة من السحابة (لا DAO محلي حتى W7.6).
/// سلّم الحالة يفرضه الخادم (`guard_withdrawal_status`): pending →
/// approved/rejected/cancelled، approved → paid/cancelled. الرفض يتطلب
/// سبباً (`rejectionReason`)، والصرف يختتم `paidAt` تلقائياً.
///
/// كل الأخطاء المُتحقَّق منها تُرمى كـ [SyncFailure] بكود ثابت (مثل
/// `AUTHORIZATION_DENIED`, `INVALID_STATUS_TRANSITION`).
abstract class PartnerWithdrawalRepository {
  /// يجلب سحوبات شريك (أو مزرعة) مرتّبة من الأحدث، مع فلاتر حالة اختيارية.
  ///
  /// الرؤية تحدّدها RLS: الشريك يرى طلباته، ومدير المزرعة يرى سحوبات
  /// مزرعته، ومدير النظام يرى الكل. الترتيب تنازلي بـ`requested_at`.
  Future<List<PartnerWithdrawal>> getWithdrawals({
    String? partnerId,
    String? farmId,
    PartnerWithdrawalStatus? status,
  });

  /// ينشئ طلب سحب `pending` نيابة عن الشريك ويعيد الطلب المخزَّن.
  ///
  /// [requestedBy] معرّف المُتصل الحالي (الشريك نفسه) — العمود `NOT NULL`
  /// بلا افتراض على الخادم. الأخطاء: `AUTHORIZATION_DENIED` إن لم يكن الشريك
  /// ملك المُتصل، `PARTNER_NOT_FOUND`، `WITHDRAWAL_DISTRIBUTION_MISMATCH`
  /// إن ارتبط التوزيع بمزرعة أخرى، و`amount <= 0` يرفضه قيد الجدول.
  Future<PartnerWithdrawal> createWithdrawal({
    required String partnerId,
    required String farmId,
    required double amount,
    required String requestedBy,
    String? distributionId,
    String? reason,
    String currency = 'dollar',
    String? notes,
  });

  /// يعتمد سحب `pending` (مدير المزرعة أو مدير النظام).
  ///
  /// [approverId] معرّف المُعتمد الحالي — تكتبه الدالة في `reviewed_by`.
  /// الأخطاء: `WITHDRAWAL_NOT_FOUND`، `AUTHORIZATION_DENIED`،
  /// `INVALID_STATUS_TRANSITION` إن لم يكن pending.
  Future<void> approveWithdrawal({
    required String withdrawalId,
    required String approverId,
  });

  /// يرفض سحب `pending` مع سبب إلزامي.
  ///
  /// الأخطاء كما في [approveWithdrawal]، ويُرفع `REJECTION_REASON_REQUIRED`
  /// محلياً إن كان [rejectionReason] فارغاً (قيد CHECK: rejected تتطلب سبباً).
  Future<void> rejectWithdrawal({
    required String withdrawalId,
    required String rejectionReason,
  });

  /// يعلّم سحب `approved` كمصروف (`paid`) مع طريقة دفع اختيارية.
  ///
  /// يختتم الخادم `paid_at` تلقائياً (قيد CHECK). الأخطاء كما في
  /// [approveWithdrawal] مع `INVALID_STATUS_TRANSITION` لغير `approved`.
  Future<void> markPaid({
    required String withdrawalId,
    String? paymentMethod,
  });

  /// يلغي سحباً بحسب سلّم الحالة (pending أو approved).
  ///
  /// `cancelled` لا يُسجَّل في `partner_audit` (بلا قيمة مطابقة في قيد
  /// الإجراءات) — السلّم يفرضه الخادم.
  Future<void> cancelWithdrawal({
    required String withdrawalId,
    String? notes,
  });

  /// سجل تدقيق شركاء (`partner_audit`) — الأحدث أولاً.
  ///
  /// يقرأه مدير النظام ومدير المزرعة فقط (RLS). سطور W7.4 التلقائية
  /// تحمل `notes` تبدأ بـ 'auto:'.
  Future<List<PartnerAuditEntry>> getPartnerAudit({
    String? farmId,
    String? partnerId,
  });

  /// ملخص شريك من RPC `partner_summary` (M24).
  ///
  /// الأخطاء: `PARTNER_NOT_FOUND`، `AUTHORIZATION_DENIED` إن لم يكن الشريك
  /// ملك المُتصل أو المُتصل مدير نظام. عند رفض RLS للـRPC يحسب الملخص
  /// مباشرة من الجداول (fallback في طبقة التنفيذ).
  Future<PartnerSummary> getPartnerSummary({required String partnerId});
}
