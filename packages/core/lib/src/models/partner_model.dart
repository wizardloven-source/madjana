import 'package:freezed_annotation/freezed_annotation.dart';

part 'partner_model.freezed.dart';
part 'partner_model.g.dart';

@freezed
class PartnerModel with _$PartnerModel {
  const factory PartnerModel({
    required String id,
    required String name,
    required String phoneNumber,
    String? email,
    String? nationalId,
    String? address,
    String? profileImageUrl,
    String? contractDocumentUrl,
    DateTime? contractStartDate,
    DateTime? contractEndDate,
    PartnerStatus status,
    double totalReceivedProfits,
    DateTime createdAt,
    DateTime updatedAt,
  }) = _PartnerModel;

  factory PartnerModel.fromJson(Map<String, dynamic> json) =>
      _$PartnerModelFromJson(json);
}

enum PartnerStatus {
  active,
  suspended,
  expired,
}

extension PartnerStatusX on PartnerStatus {
  String get arabicName {
    switch (this) {
      case PartnerStatus.active:
        return 'نشط';
      case PartnerStatus.suspended:
        return 'موقوف';
      case PartnerStatus.expired:
        return 'منتهي العقد';
    }
  }
}

@freezed
class PartnerFarmRelation with _$PartnerFarmRelation {
  const factory PartnerFarmRelation({
    required String id,
    required String partnerId,
    required String farmId,
    String? farmName,
    required String role, // مول، صاحب أرض، إلخ
    required double percentage,
    required bool bearsLoss,
    DateTime? startDate,
    DateTime? endDate,
    PartnerStatus status,
    DateTime createdAt,
  }) = _PartnerFarmRelation;

  factory PartnerFarmRelation.fromJson(Map<String, dynamic> json) =>
      _$PartnerFarmRelationFromJson(json);
}

@freezed
class PartnerTransaction with _$PartnerTransaction {
  const factory PartnerTransaction({
    required String id,
    required String partnerId,
    String? farmId,
    String? farmName,
    required String description,
    required DateTime date,
    double? credit, // دائن (له)
    double? debit, // مدين (عليه)
    required double balance, // الرصيد
    String? paymentMethod, // كاش، تحويل بنكي، شيك
    String? receiptImageUrl,
    String transactionType, // profit, withdrawal, advance, settlement
    DateTime createdAt,
  }) = _PartnerTransaction;

  factory PartnerTransaction.fromJson(Map<String, dynamic> json) =>
      _$PartnerTransactionFromJson(json);
}

@freezed
class PartnerWithdrawal with _$PartnerWithdrawal {
  const factory PartnerWithdrawal({
    required String id,
    required String partnerId,
    required double amount,
    required DateTime date,
    String? description,
    String? paymentMethod,
    String? receiptImageUrl,
    bool isSettled,
    DateTime createdAt,
  }) = _PartnerWithdrawal;

  factory PartnerWithdrawal.fromJson(Map<String, dynamic> json) =>
      _$PartnerWithdrawalFromJson(json);
}

@freezed
class PartnerContractAlert with _$PartnerContractAlert {
  const factory PartnerContractAlert({
    required String partnerId,
    required String partnerName,
    String? farmId,
    String? farmName,
    required DateTime endDate,
    required int daysRemaining,
  }) = _PartnerContractAlert;

  factory PartnerContractAlert.fromJson(Map<String, dynamic> json) =>
      _$PartnerContractAlertFromJson(json);
}
