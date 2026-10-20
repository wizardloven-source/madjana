import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'supabase_api.dart';

/// سحوبات الشركاء وملخّصهم عبر Supabase (W7.4).
///
/// * الإنشاء/الرفض/الصرف/الإلغاء تحديثات مباشرة على `partner_withdrawals`
///   يفرض سلّمها الخادم (`guard_withdrawal_status`)؛ الاعتماد وحده يستدعي
///   RPC `approve_withdrawal` (M24) ليختم `reviewed_by`/`reviewed_at`
///   مركزياً.
/// * `getPartnerSummary` يستدعي RPC `partner_summary` (M24)؛ وعند رفض RLS
///   للمدير (بوابة الدالة المالك/مدير النظام فقط) يُعاد حساب الملخص من
///   الجداول مباشرة بدل إسقاط الشاشة.
/// * أخطاء PostgREST تُترجم إلى [SyncFailure] بكود ثابت
///   (`mapWithdrawalFailure`).
class SupabaseWithdrawalDatasource {
  final SupabaseApi _api;

  SupabaseWithdrawalDatasource(this._api);

  /// سحوبات مرتّبة من الأحدث بـ`requested_at`، بفلاتر اختيارية.
  ///
  /// الرؤية تحدّدها RLS على الخادم (شريك/مدير مزرعة/مدير نظام).
  Future<List<PartnerWithdrawal>> getWithdrawals({
    String? partnerId,
    String? farmId,
    PartnerWithdrawalStatus? status,
  }) async {
    var query =
        _api.from('partner_withdrawals').select(columns: _withdrawalColumns);
    if (partnerId != null) query = query.eq('partner_id', partnerId);
    if (farmId != null) query = query.eq('farm_id', farmId);
    if (status != null) query = query.eq('status', status.name);
    final rows = await query.order('requested_at', ascending: false).get();
    return rows.map(PartnerWithdrawal.fromJson).toList();
  }

  /// ينشئ طلب سحب `pending` ويعيد الصف المخزَّن كما يراه الخادم.
  ///
  /// `requested_at` غير مُمرَّر: العمود `DEFAULT now()` على الخادم.
  Future<PartnerWithdrawal> createWithdrawal({
    required String partnerId,
    required String farmId,
    required double amount,
    required String requestedBy,
    String? distributionId,
    String? reason,
    String currency = 'dollar',
    String? notes,
  }) async {
    try {
      final row = await _api
          .from('partner_withdrawals')
          .insert(<String, dynamic>{
            'partner_id': partnerId,
            'farm_id': farmId,
            'distribution_id': distributionId,
            'amount': amount,
            'currency': currency,
            'status': 'pending',
            'requested_by': requestedBy,
            'reason': reason,
            'notes': notes,
          })
          .select(_withdrawalColumns)
          .single();
      return PartnerWithdrawal.fromJson(row);
    } catch (e) {
      throw mapWithdrawalFailure(e);
    }
  }

  /// يعتمد سحب `pending` عبر RPC `approve_withdrawal` (M24).
  Future<void> approveWithdrawal({
    required String withdrawalId,
    required String approverId,
  }) async {
    try {
      await _api.rpc('approve_withdrawal', params: {
        'p_withdrawal_id': withdrawalId,
        'p_approver_id': approverId,
      });
    } catch (e) {
      throw mapWithdrawalFailure(e);
    }
  }

  /// يرفض سحب `pending` (تحديث مباشر — السلّم يفرضه الخادم).
  ///
  /// المرشّح `status = 'pending'` يمنع كتماناً لحالة تغيّرت في نفس اللحظة؛
  /// غياب الصف يعني `WITHDRAWAL_CONFLICT`.
  Future<void> rejectWithdrawal({
    required String withdrawalId,
    required String rejectionReason,
  }) async {
    if (rejectionReason.trim().isEmpty) {
      throw SyncFailure('REJECTION_REASON_REQUIRED',
          'سبب الرفض إلزامي (قيد CHECK على partner_withdrawals)');
    }
    try {
      final row = await _api
          .from('partner_withdrawals')
          .update({
            'status': 'rejected',
            'rejection_reason': rejectionReason,
          })
          .eq('id', withdrawalId)
          .eq('status', 'pending')
          .select(_withdrawalColumns)
          .maybeSingle();
      if (row == null) {
        throw SyncFailure('WITHDRAWAL_CONFLICT',
            'السحب $withdrawalId غير موجود أو ليس pending');
      }
    } catch (e) {
      throw mapWithdrawalFailure(e);
    }
  }

  /// يعلّم سحب `approved` كمصروف (الخادم يختتم `paid_at` تلقائياً).
  Future<void> markPaid({
    required String withdrawalId,
    String? paymentMethod,
  }) async {
    try {
      final row = await _api
          .from('partner_withdrawals')
          .update({
            'status': 'paid',
            'payment_method': paymentMethod,
          })
          .eq('id', withdrawalId)
          .eq('status', 'approved')
          .select(_withdrawalColumns)
          .maybeSingle();
      if (row == null) {
        throw SyncFailure('WITHDRAWAL_CONFLICT',
            'السحب $withdrawalId غير موجود أو ليس approved');
      }
    } catch (e) {
      throw mapWithdrawalFailure(e);
    }
  }

  /// يلغي سحباً بحسب سلّم الحالة (يفرضه `guard_withdrawal_status`).
  ///
  /// بلا مرشّح حالة على العميل: الرفض يأتي من الخادم
  /// (`INVALID_STATUS_TRANSITION`) إن كانت الحالة لا تقبل الإلغاء.
  Future<void> cancelWithdrawal({
    required String withdrawalId,
    String? notes,
  }) async {
    final values = <String, dynamic>{'status': 'cancelled'};
    if (notes != null) values['notes'] = notes;
    try {
      final row = await _api
          .from('partner_withdrawals')
          .update(values)
          .eq('id', withdrawalId)
          .select(_withdrawalColumns)
          .maybeSingle();
      if (row == null) {
        throw SyncFailure(
            'WITHDRAWAL_NOT_FOUND', 'السحب $withdrawalId غير موجود');
      }
    } catch (e) {
      throw mapWithdrawalFailure(e);
    }
  }

  /// سجل تدقيق الشركاء (`partner_audit`) — الأحدث أولاً، بفلاتر اختيارية.
  Future<List<PartnerAuditEntry>> getPartnerAudit({
    String? farmId,
    String? partnerId,
  }) async {
    var query = _api.from('partner_audit').select(columns: _auditColumns);
    if (partnerId != null) query = query.eq('partner_id', partnerId);
    if (farmId != null) query = query.eq('farm_id', farmId);
    final rows = await query.order('changed_at', ascending: false).get();
    return rows.map(PartnerAuditEntry.fromJson).toList();
  }

  /// ملخص شريك من RPC `partner_summary` (M24) مع حساب بديل محلي.
  ///
  /// الدالة تقبل المالك أو مدير النظام فقط؛ مدير مزرعة الشريك يُرفض
  /// بـ`AUTHORIZATION_DENIED` فنحسب الملخص من الجداول (بعض الاستعلامات
  /// أكثر من RPC لكن الحالة تظل متسقة مع RLS نفس الاستعلامات).
  Future<PartnerSummary> getPartnerSummary({required String partnerId}) async {
    try {
      final data =
          await _api.rpc('partner_summary', params: {'p_partner_id': partnerId});
      if (data is List && data.isNotEmpty) {
        return PartnerSummary.fromJson(
            Map<String, dynamic>.from(data.first as Map));
      }
    } catch (e) {
      final failure = mapWithdrawalFailure(e);
      // غير رفض البوابة: نُعيد الرمي مُحوَّلاً كـ SyncFailure متسقة.
      if (failure.code != 'AUTHORIZATION_DENIED') throw failure;
    }
    return _computeSummary(partnerId);
  }

  /// حساب الملخص مباشرة من الجداول (للمدير الذي يُرفض ببوابة RPC).
  ///
  /// نفس منطق M24: صافي الربح = مجموع `profit_share` في بنود التوزيعات
  /// المعتمدة؛ المعلّق = سحوبات pending + approved؛ المدفوع = paid.
  Future<PartnerSummary> _computeSummary(String partnerId) async {
    final partner =
        await _api.from('partners').select().eq('id', partnerId).maybeSingle();
    if (partner == null) {
      throw SyncFailure('PARTNER_NOT_FOUND',
          'الشريك $partnerId غير موجود أو غير مرئي للمُتصل');
    }

    var netProfit = 0.0;
    final dists = await _api
        .from('profit_distributions')
        .select(columns: ['id'])
        .eq('status', 'approved')
        .get();
    if (dists.isNotEmpty) {
      final details = await _api
          .from('profit_distribution_details')
          .select(columns: ['profit_share'])
          .eq('partner_id', partnerId)
          .inFilter('distribution_id', dists.map((d) => d['id']).toList())
          .get();
      for (final d in details) {
        netProfit += _toDouble(d['profit_share']) ?? 0;
      }
    }

    var pending = 0.0;
    var paid = 0.0;
    final withdrawals = await _api
        .from('partner_withdrawals')
        .select(columns: ['status', 'amount'])
        .eq('partner_id', partnerId)
        .get();
    for (final w in withdrawals) {
      final amount = _toDouble(w['amount']) ?? 0;
      switch (w['status']?.toString()) {
        case 'pending':
        case 'approved':
          pending += amount;
        case 'paid':
          paid += amount;
      }
    }

    return PartnerSummary(
      name: (partner['name'] ?? '').toString(),
      shareModel: (partner['share_model'] ?? 'percentage').toString(),
      shareValue: _shareValueOf(partner),
      netProfit: netProfit,
      pending: pending,
      paid: paid,
    );
  }

  /// قيمة الحصة بحسب النموذج — نفس تفرّع M24 (mixed = أول قيمة موجودة).
  double? _shareValueOf(Map<String, dynamic> partner) {
    switch (partner['share_model']?.toString()) {
      case 'percentage':
        return _toDouble(partner['percentage']);
      case 'shares':
        return _toDouble(partner['shares']);
      case 'salary':
        return _toDouble(partner['salary_amount']);
      case 'mixed':
        return _toDouble(partner['percentage']) ??
            _toDouble(partner['shares']) ??
            _toDouble(partner['salary_amount']);
      default:
        return null;
    }
  }
}

/// أعمدة سحبات الشركاء التي تقرأها العقود (W7.4-UI).
const _withdrawalColumns = <String>[
  'id',
  'partner_id',
  'farm_id',
  'distribution_id',
  'amount',
  'currency',
  'status',
  'requested_at',
  'requested_by',
  'reason',
  'reviewed_at',
  'reviewed_by',
  'rejection_reason',
  'paid_at',
  'payment_method',
  'notes',
];

/// أعمدة سجل التدقيق (`partner_audit`) — قراءة فقط.
const _auditColumns = <String>[
  'id',
  'farm_id',
  'partner_id',
  'action',
  'old_values',
  'new_values',
  'changed_by',
  'changed_at',
  'notes',
];

/// أكواد أخطاء سحوبات الشركاء كما تُطلقها القاعدة (M23/M24) أو العميل.
const _withdrawalCodes = <String>[
  'AUTHORIZATION_DENIED',
  'WITHDRAWAL_NOT_FOUND',
  'INVALID_STATUS_TRANSITION',
  'PARTNER_NOT_FOUND',
  'WITHDRAWAL_DISTRIBUTION_MISMATCH',
  'NO_SESSION',
];

/// يحوّل خطأ PostgREST/الشبكة إلى [SyncFailure] بكود ثابت واضح.
///
/// رسالة Postgres تأتي بالشكل `CODE: وصف`؛ نستخرج الكود الأول المعروف ونحفظ
/// الرسالة الكاملة كـ[SyncFailure.message]. أخطاء العميل المُرمية كـ
/// [SyncFailure] تمرّ كما هي.
SyncFailure mapWithdrawalFailure(Object error) {
  if (error is SyncFailure) return error;
  final message = _postgrestMessage(error);
  final code = _withdrawalCodes.firstWhere(
    (c) => message.contains(c),
    orElse: () => 'UNKNOWN',
  );
  return SyncFailure(code, message, error);
}

String _postgrestMessage(Object error) {
  try {
    final msg = (error as dynamic).message as String?;
    if (msg != null && msg.trim().isNotEmpty) return msg.trim();
  } catch (e) {
    // بلا getter message (خطأ شبكة/StateError) — نطبع السبب ونكمل للنصّ الكامل.
    debugPrint('madjana: withdrawal error message extract failed: $e');
  }
  return error.toString().replaceFirst('Exception: ', '');
}

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}
