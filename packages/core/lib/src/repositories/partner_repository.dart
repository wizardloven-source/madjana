import 'package:core/core.dart';

/// واجهة مستودع إدارة الشركاء
abstract class PartnerRepository {
  /// إنشاء/تحديث شريك
  Future<void> savePartner(PartnerModel partner);

  /// حذف شريك (Soft delete)
  Future<void> deletePartner(String partnerId);

  /// جلب جميع الشركاء (للمالك)
  Future<List<PartnerModel>> getAllPartners({
    String? farmId,
    PartnerStatus? status,
  });

  /// جلب شريك حسب ID
  Future<PartnerModel?> getPartnerById(String partnerId);

  /// جلب شركاء مدجنة معينة
  Future<List<PartnerModel>> getPartnersByFarm(String farmId);

  /// جلب علاقات الشريك بالمزارع
  Future<List<PartnerFarmRelation>> getPartnerFarmRelations(String partnerId);

  /// إضافة علاقة شريك بمدجنة
  Future<void> addPartnerToFarm(PartnerFarmRelation relation);

  /// تحديث علاقة شريك بمدجنة
  Future<void> updatePartnerFarmRelation(PartnerFarmRelation relation);

  /// إزالة شريك من مدجنة
  Future<void> removePartnerFromFarm(String partnerId, String farmId);

  /// إضافة معاملة مالية للشريك
  Future<void> addTransaction(PartnerTransaction transaction);

  /// جلب المعاملات المالية للشريك
  Future<List<PartnerTransaction>> getPartnerTransactions(
    String partnerId, {
    DateTime? fromDate,
    DateTime? toDate,
  });

  /// جلب الرصيد الحالي للشريك
  Future<double> getPartnerBalance(String partnerId);

  /// صرف ربح للشريك
  Future<void> distributeProfit({
    required String partnerId,
    required String farmId,
    required double amount,
    required String description,
    DateTime? date,
  });

  /// تسجيل سحب للشريك
  Future<void> recordWithdrawal({
    required String partnerId,
    required double amount,
    String? description,
    String? paymentMethod,
    String? receiptImageUrl,
    DateTime? date,
  });

  /// تسوية حساب الشريك
  Future<void> settleAccount(String partnerId);

  /// توزيع الأرباح على شركاء مدجنة معينة
  Future<void> distributeFarmProfits({
    required String farmId,
    required double totalProfit,
    required String description,
    DateTime? date,
  });

  /// جلب تنبيهات العقود المنتهية أو القريبة من الانتهاء
  Future<List<PartnerContractAlert>> getContractAlerts({int daysThreshold = 30});

  /// رفع مستند عقد الشراكة
  Future<String> uploadContractDocument({
    required String partnerId,
    required Uint8List fileBytes,
    required String fileName,
  });

  /// نقل حصة شريك متوفى إلى ورثة
  Future<void> transferShareToHeirs({
    required String deceasedPartnerId,
    required List<HeirAllocation> heirs,
  });

  /// جلب تقرير شامل للشريك
  Future<PartnerReport> getPartnerReport({
    required String partnerId,
    DateTime? fromDate,
    DateTime? toDate,
  });

  /// تصدير بيانات الشركاء إلى Excel
  Future<Uint8List> exportPartnersToExcel({String? farmId});

  /// استيراد شركاء من Excel
  Future<List<PartnerModel>> importPartnersFromExcel(Uint8List excelBytes);

  /// تسجيل عملية في سجل التدقيق
  Future<void> logAuditEntry({
    required String partnerId,
    required String action,
    required String userId,
    String? details,
  });
}

/// نموذج لتوزيع الميراث
class HeirAllocation {
  final String heirName;
  final String heirNationalId;
  final double percentage;
  final String relationship;

  HeirAllocation({
    required this.heirName,
    required this.heirNationalId,
    required this.percentage,
    required this.relationship,
  });

  Map<String, dynamic> toJson() => {
        'heir_name': heirName,
        'heir_national_id': heirNationalId,
        'percentage': percentage,
        'relationship': relationship,
      };
}

/// نموذج التقرير الشامل
class PartnerReport {
  final PartnerModel partner;
  final List<PartnerFarmRelation> farmRelations;
  final List<PartnerTransaction> transactions;
  final double totalCredits;
  final double totalDebits;
  final double currentBalance;
  final double totalProfitsReceived;
  final Map<String, double> profitsByFarm;
  final List<PartnerContractAlert> alerts;

  PartnerReport({
    required this.partner,
    required this.farmRelations,
    required this.transactions,
    required this.totalCredits,
    required this.totalDebits,
    required this.currentBalance,
    required this.totalProfitsReceived,
    required this.profitsByFarm,
    required this.alerts,
  });

  Map<String, dynamic> toJson() => {
        'partner': partner.toJson(),
        'farm_relations': farmRelations.map((r) => r.toJson()).toList(),
        'transactions': transactions.map((t) => t.toJson()).toList(),
        'total_credits': totalCredits,
        'total_debits': totalDebits,
        'current_balance': currentBalance,
        'total_profits_received': totalProfitsReceived,
        'profits_by_farm': profitsByFarm,
        'alerts': alerts.map((a) => a.toJson()).toList(),
      };
}
