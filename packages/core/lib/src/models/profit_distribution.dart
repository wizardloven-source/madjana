/// حالة رأس توزيع الأرباح (`profit_distributions.status`).
///
/// القيم تطابق نصّ العمود حرفياً (draft/calculated/approved/distributed/
/// cancelled) — راجع قيد CHECK في M22.
enum ProfitDistributionStatus {
  draft('مسودة'),
  calculated('محسوب'),
  approved('معتمد'),
  distributed('موزّع'),
  cancelled('ملغى');

  const ProfitDistributionStatus(this.label);

  /// تسمية عربية للعرض في الواجهة.
  final String label;

  /// يحوّل نصّ العمود إلى الحالة، ويعود إلى [draft] عند قيمة غير معروفة.
  static ProfitDistributionStatus fromName(String? value) =>
      ProfitDistributionStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => ProfitDistributionStatus.draft,
      );
}

/// رأس توزيع أرباح مخزَّن في `profit_distributions` (M22/M30).
///
/// يُقرأ لعرض الحالة (`draft`/`approved`/...) وإظهار أزرار الإنشاء/الاعتماد
/// في الواجهة. المبالغ بالدولار دائماً (M29v2).
class ProfitDistribution {
  /// معرّف الرأس (`id`).
  final String id;

  /// معرّف المزرعة (`farm_id`).
  final String farmId;

  /// معرّف القطيع (`flock_id`) أو `null` لكامل المزرعة.
  final String? flockId;

  /// بداية الفترة (`period_start`).
  final DateTime periodStart;

  /// نهاية الفترة (`period_end`).
  final DateTime periodEnd;

  /// وسم اختياري (`label`).
  final String? label;

  /// حالة الرأس (`status`).
  final ProfitDistributionStatus status;

  /// إيراد الفترة (`total_revenue`).
  final double totalRevenue;

  /// مصروف الفترة (`total_expenses`).
  final double totalExpenses;

  /// صافي الربح (`net_profit = total_revenue - total_expenses`).
  final double netProfit;

  /// الاحتياطي (`reserve_amount`).
  final double reserveAmount;

  /// القابل للتوزيع (`distributable_profit = net_profit - reserve_amount`).
  final double distributableProfit;

  /// وقت الاعتماد (`approved_at`) إن وُجد.
  final DateTime? approvedAt;

  /// معرّف من اعتمد الرأس (`approved_by`) إن وُجد.
  final String? approvedBy;

  /// ملاحظات اختيارية (`notes`).
  final String? notes;

  const ProfitDistribution({
    required this.id,
    required this.farmId,
    this.flockId,
    required this.periodStart,
    required this.periodEnd,
    this.label,
    required this.status,
    required this.totalRevenue,
    required this.totalExpenses,
    required this.netProfit,
    required this.reserveAmount,
    required this.distributableProfit,
    this.approvedAt,
    this.approvedBy,
    this.notes,
  });

  /// هل الرأس ما زال مسودة (قابلاً للاعتماد)؟
  bool get isDraft => status == ProfitDistributionStatus.draft;

  factory ProfitDistribution.fromJson(Map<String, dynamic> json) {
    return ProfitDistribution(
      id: (json['id'] ?? '').toString(),
      farmId: (json['farm_id'] ?? '').toString(),
      flockId: json['flock_id']?.toString(),
      periodStart: _parseDateTime(json['period_start']) ?? DateTime(1970),
      periodEnd: _parseDateTime(json['period_end']) ?? DateTime(1970),
      label: json['label']?.toString(),
      status: ProfitDistributionStatus.fromName(json['status']?.toString()),
      totalRevenue: _toDouble(json['total_revenue']) ?? 0,
      totalExpenses: _toDouble(json['total_expenses']) ?? 0,
      netProfit: _toDouble(json['net_profit']) ?? 0,
      reserveAmount: _toDouble(json['reserve_amount']) ?? 0,
      distributableProfit: _toDouble(json['distributable_profit']) ?? 0,
      approvedAt: _parseDateTime(json['approved_at']),
      approvedBy: json['approved_by']?.toString(),
      notes: json['notes']?.toString(),
    );
  }
}

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

DateTime? _parseDateTime(dynamic v) =>
    v == null ? null : DateTime.tryParse(v.toString());
