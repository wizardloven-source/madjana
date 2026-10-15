import '../constants/enums.dart';

/// سطر معاينة توزيع أرباح — ناتج `calculate_profit_distribution` (M24/M29v2).
///
/// الدالة **read-only**: تُعاين حصة كل شريك من صافي الربح دون أن تكتب أي صف
/// في `profit_distributions`/`profit_distribution_details`. المبالغ بالدولار
/// دائماً (M29v2: `currency` بيانات وصفية لا وحدة تحويل).
class ProfitDistributionPreview {
  /// معرّف الشريك (`partner_id`).
  final String partnerId;

  /// النموذج الذي سعّر السطر (`share_type`) — نفس تعداد [ShareModel].
  final ShareModel shareType;

  /// مدخل النموذج (نسبة/أسهم/راتب) كما أعادته الدالة.
  final double? shareValue;

  /// حصة الشريك من الربح + راتبه إن وُجد (بالدولار).
  final double amount;

  const ProfitDistributionPreview({
    required this.partnerId,
    required this.shareType,
    required this.shareValue,
    required this.amount,
  });

  factory ProfitDistributionPreview.fromJson(Map<String, dynamic> json) {
    return ProfitDistributionPreview(
      partnerId: (json['partner_id'] ?? '').toString(),
      shareType: ShareModel.fromName(json['share_type']?.toString()),
      shareValue: _toDouble(json['share_value']),
      amount: _toDouble(json['amount']) ?? 0,
    );
  }
}

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}
