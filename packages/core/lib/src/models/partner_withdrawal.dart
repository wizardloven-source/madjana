/// حالة طلب سحب شريك (`partner_withdrawals.status` — قيد CHECK في M23).
///
/// القيم تطابق نصّ العمود حرفياً (pending/approved/rejected/paid/cancelled).
enum PartnerWithdrawalStatus {
  pending('قيد المراجعة'),
  approved('معتمد'),
  rejected('مرفوض'),
  paid('مدفوع'),
  cancelled('ملغى');

  const PartnerWithdrawalStatus(this.label);

  /// تسمية عربية للعرض في الواجهة.
  final String label;

  /// يحوّل نصّ العمود إلى الحالة، ويعود إلى [pending] عند قيمة غير معروفة.
  static PartnerWithdrawalStatus fromName(String? value) =>
      PartnerWithdrawalStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => PartnerWithdrawalStatus.pending,
      );
}

/// طلب سحب شريك (`partner_withdrawals` — M23، دورة حياة W7.4).
///
/// يقرأ من السحابة مباشرة (لا DAO محلي حتى W7.6). سلّم الحالة يفرضه
/// الخادم (`guard_withdrawal_status`): pending → approved/rejected/cancelled،
/// approved → paid/cancelled. الرفض يتطلب `rejectionReason` (قيد CHECK)،
/// والصرف يتطلب `paidAt` (يختمه الخادم تلقائياً).
class PartnerWithdrawal {
  /// معرّف الطلب (`id`).
  final String id;

  /// الشريك صاحب الطلب (`partner_id`).
  final String partnerId;

  /// المزرعة (`farm_id`) — توزيع مرتبط بها لا يكون لمزرعة أخرى.
  final String farmId;

  /// التوزيع المرتبط بالطلب (`distribution_id`) إن وُجد.
  final String? distributionId;

  /// المبلغ (`amount`، موجب دائماً).
  final double amount;

  /// العملة (`currency`) — 'dollar' افتراضياً.
  final String currency;

  /// حالة الطلب (`status`).
  final PartnerWithdrawalStatus status;

  /// وقت الإنشاء (`requested_at`) — يضبطه الخادم.
  final DateTime? requestedAt;

  /// من أنشأ الطلب (`requested_by`).
  final String requestedBy;

  /// سبب الطلب (`reason`).
  final String? reason;

  /// وقت المراجعة (`reviewed_at`) — يختمه الخادم عند الاعتماد/الرفض.
  final DateTime? reviewedAt;

  /// المراجع (`reviewed_by`) — يكتبه الخادم من مُنفِّذ الإجراء.
  final String? reviewedBy;

  /// سبب الرفض (`rejection_reason`) — إلزامي عند status = rejected.
  final String? rejectionReason;

  /// وقت الصرف (`paid_at`) — يختمه الخادم عند status = paid.
  final DateTime? paidAt;

  /// طريقة الدفع (`payment_method`).
  final String? paymentMethod;

  /// ملاحظات (`notes`).
  final String? notes;

  const PartnerWithdrawal({
    required this.id,
    required this.partnerId,
    required this.farmId,
    this.distributionId,
    required this.amount,
    this.currency = 'dollar',
    required this.status,
    this.requestedAt,
    required this.requestedBy,
    this.reason,
    this.reviewedAt,
    this.reviewedBy,
    this.rejectionReason,
    this.paidAt,
    this.paymentMethod,
    this.notes,
  });

  /// هل الطلب ما زال قيد المراجعة؟
  bool get isPending => status == PartnerWithdrawalStatus.pending;

  /// هل الطلب مرفوض؟
  bool get isRejected => status == PartnerWithdrawalStatus.rejected;

  /// هل الطلب مدفوع؟
  bool get isPaid => status == PartnerWithdrawalStatus.paid;

  factory PartnerWithdrawal.fromJson(Map<String, dynamic> json) {
    return PartnerWithdrawal(
      id: (json['id'] ?? '').toString(),
      partnerId: (json['partner_id'] ?? '').toString(),
      farmId: (json['farm_id'] ?? '').toString(),
      distributionId: json['distribution_id']?.toString(),
      amount: _toDouble(json['amount']) ?? 0,
      currency: (json['currency'] ?? 'dollar').toString(),
      status: PartnerWithdrawalStatus.fromName(json['status']?.toString()),
      requestedAt: _parseDateTime(json['requested_at']),
      requestedBy: (json['requested_by'] ?? '').toString(),
      reason: json['reason']?.toString(),
      reviewedAt: _parseDateTime(json['reviewed_at']),
      reviewedBy: json['reviewed_by']?.toString(),
      rejectionReason: json['rejection_reason']?.toString(),
      paidAt: _parseDateTime(json['paid_at']),
      paymentMethod: json['payment_method']?.toString(),
      notes: json['notes']?.toString(),
    );
  }

  /// JSON للإرسال إلى القاعدة.
  ///
  /// لا يحمل `requested_at`/`reviewed_at`/`paid_at` (وقتها يضعها الخادم)،
  /// ولا `id` (توليد الخادم) — عمود `requested_at` بخاصة هو
  /// `DEFAULT now()` ولا يُكتب من العميل (تعليم W7.4).
  Map<String, dynamic> toJson() => {
        'partner_id': partnerId,
        'farm_id': farmId,
        'distribution_id': distributionId,
        'amount': amount,
        'currency': currency,
        'status': status.name,
        'requested_by': requestedBy,
        'reason': reason,
        'reviewed_by': reviewedBy,
        'rejection_reason': rejectionReason,
        'payment_method': paymentMethod,
        'notes': notes,
      };
}

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

DateTime? _parseDateTime(dynamic v) =>
    v == null ? null : DateTime.tryParse(v.toString());
