import '../constants/enums.dart';

/// شريك — صفّ في `public.partners` (W6-M21).
///
/// الشريك **سمة شخص لا دور**: قد يكون بلا حساب (`user_id` اختياري)، والكتابة
/// عليه محصورة بـ`is_system_admin()` في RLS. نموذج الحصة ديناميكي —
/// [shareModel] يحدّد أي الأعمدة المالية هي المصدر (percentage/shares/salary).
class PartnerModel {
  final String? id;
  final String? userId;
  final String name;
  final String? phone;
  final String? nationalId;
  final PartnerStatus status;
  final PartnerRole partnerRole;
  final ShareModel shareModel;
  final double? percentage;
  final double? shares;
  final double? salaryAmount;
  final SalaryPeriod? salaryPeriod;
  final AppCurrency currency;
  final DateTime? effectiveFrom;
  final DateTime? effectiveTo;
  final String? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  const PartnerModel({
    this.id,
    this.userId,
    required this.name,
    this.phone,
    this.nationalId,
    this.status = PartnerStatus.active,
    this.partnerRole = PartnerRole.investor,
    this.shareModel = ShareModel.percentage,
    this.percentage,
    this.shares,
    this.salaryAmount,
    this.salaryPeriod,
    this.currency = AppCurrency.dollar,
    this.effectiveFrom,
    this.effectiveTo,
    this.createdBy,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;

  /// هل الحقول تلبّي قيد `partners_share_model_fields`?
  ///
  /// يجب أن يوافق `share_model` الأعمدة المملوءة، وإلا رفضته القاعدة.
  bool get hasValidShareFields {
    switch (shareModel) {
      case ShareModel.percentage:
        return percentage != null && percentage! >= 0 && percentage! <= 100;
      case ShareModel.shares:
        return shares != null && shares! >= 0;
      case ShareModel.salary:
        return salaryAmount != null &&
            salaryAmount! >= 0 &&
            salaryPeriod != null;
      case ShareModel.mixed:
        return salaryAmount != null &&
            salaryAmount! >= 0 &&
            salaryPeriod != null &&
            (percentage != null || shares != null);
    }
  }

  factory PartnerModel.fromJson(Map<String, dynamic> json) {
    return PartnerModel(
      id: json['id']?.toString(),
      userId: json['user_id']?.toString(),
      name: (json['name'] ?? '').toString(),
      phone: json['phone']?.toString(),
      nationalId: json['national_id']?.toString(),
      status: PartnerStatus.fromName(json['status']?.toString()),
      partnerRole: PartnerRole.fromName(json['partner_role']?.toString()),
      shareModel: ShareModel.fromName(json['share_model']?.toString()),
      percentage: _toDouble(json['percentage']),
      shares: _toDouble(json['shares']),
      salaryAmount: _toDouble(json['salary_amount']),
      salaryPeriod: SalaryPeriod.fromDb(json['salary_period']?.toString()),
      currency: AppCurrency.fromName(json['currency']?.toString()),
      effectiveFrom: _toDate(json['effective_from']),
      effectiveTo: _toDate(json['effective_to']),
      createdBy: json['created_by']?.toString(),
      createdAt: _toDate(json['created_at']),
      updatedAt: _toDate(json['updated_at']),
      deletedAt: _toDate(json['deleted_at']),
    );
  }

  /// أعمدة الكتابة فقط (بلا created_at/updated_at/deleted_at التي تديرها القاعدة).
  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'user_id': userId,
        'name': name,
        'phone': phone,
        'national_id': nationalId,
        'status': status.name,
        'partner_role': partnerRole.name,
        'share_model': shareModel.name,
        'percentage': percentage,
        'shares': shares,
        'salary_amount': salaryAmount,
        'salary_period': salaryPeriod?.dbValue,
        'currency': currency.name,
        if (effectiveFrom != null)
          'effective_from': _formatDate(effectiveFrom!),
        'effective_to': effectiveTo == null ? null : _formatDate(effectiveTo!),
      };
}

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

DateTime? _toDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  return DateTime.tryParse(v.toString());
}

String _formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
