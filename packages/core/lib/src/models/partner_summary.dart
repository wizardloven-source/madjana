/// ملخص شريك من RPC `partner_summary` (M24) أو حساب مباشر (W7.4 fallback).
///
/// القاعدة ترجع: name, share_model, share_value, net_profit, pending, paid.
/// الرصيد المعلّق = مجموع سحوبات pending + approved؛ المدفوع = paid.
class PartnerSummary {
  /// اسم الشريك (`partners.name`).
  final String name;

  /// نموذج الحصة (`share_model`) — percentage/shares/salary/mixed.
  final String shareModel;

  /// قيمة الحصة المحسوبة من النموذج (`share_value`) إن وُجدت.
  final double? shareValue;

  /// صافي ربح الشريك خلال السنة الحالية حتى اليوم (`net_profit`).
  final double netProfit;

  /// مجموع السحوبات المعلّقة: pending + approved (`pending`).
  final double pending;

  /// مجموع السحوبات المصروفة (`paid`).
  final double paid;

  const PartnerSummary({
    required this.name,
    required this.shareModel,
    this.shareValue,
    required this.netProfit,
    required this.pending,
    required this.paid,
  });

  /// الرصيد الصافي المتاح للصرف تقريباً (ربح − معلّق − مدفوع).
  double get available => netProfit - pending - paid;

  factory PartnerSummary.fromJson(Map<String, dynamic> json) {
    return PartnerSummary(
      name: (json['name'] ?? '').toString(),
      shareModel: (json['share_model'] ?? 'percentage').toString(),
      shareValue: _toDouble(json['share_value']),
      netProfit: _toDouble(json['net_profit']) ?? 0,
      pending: _toDouble(json['pending']) ?? 0,
      paid: _toDouble(json['paid']) ?? 0,
    );
  }
}

/// سجل تدقيق شركاء (`partner_audit` — M23، محفّز W7.4).
///
/// الجدول append-only: العميل يقرأ فقط؛ الكتابة من الخادم
/// (`record_partner_audit` ومحفّز السحبات W7.4).
class PartnerAuditEntry {
  /// معرّف السطر (`id`).
  final String id;

  /// المزرعة (`farm_id`).
  final String farmId;

  /// الشريك (`partner_id`) إن وُجد (سطور التوزيعات بلا شريك = null).
  final String? partnerId;

  /// الإجراء (`action`) — من قيد CHECK في M23/W7.4.
  final String action;

  /// القيم قبل (`old_values`).
  final Map<String, dynamic>? oldValues;

  /// القيم بعد (`new_values`).
  final Map<String, dynamic>? newValues;

  /// من نفّذ العملية (`changed_by`).
  final String changedBy;

  /// وقت العملية (`changed_at`).
  final DateTime? changedAt;

  /// ملاحظات (`notes`) — سطور W7.4 التلقائية تحمل 'auto: ...'.
  final String? notes;

  const PartnerAuditEntry({
    required this.id,
    required this.farmId,
    this.partnerId,
    required this.action,
    this.oldValues,
    this.newValues,
    required this.changedBy,
    this.changedAt,
    this.notes,
  });

  /// هل السطر من محفّز W7.4 التلقائي؟
  bool get isAuto => notes?.startsWith('auto:') ?? false;

  factory PartnerAuditEntry.fromJson(Map<String, dynamic> json) {
    return PartnerAuditEntry(
      id: (json['id'] ?? '').toString(),
      farmId: (json['farm_id'] ?? '').toString(),
      partnerId: json['partner_id']?.toString(),
      action: (json['action'] ?? '').toString(),
      oldValues: _toMap(json['old_values']),
      newValues: _toMap(json['new_values']),
      changedBy: (json['changed_by'] ?? '').toString(),
      changedAt: json['changed_at'] == null
          ? null
          : DateTime.tryParse(json['changed_at'].toString()),
      notes: json['notes']?.toString(),
    );
  }
}

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

Map<String, dynamic>? _toMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;
