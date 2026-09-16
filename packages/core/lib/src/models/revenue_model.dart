import '../constants/enums.dart';

class RevenueModel {
  final String? id;
  final String farmId;
  final DateTime date;
  final RevenueCategory category;
  final String? description;
  final double amount;
  final AppCurrency currency;
  final double? exchangeRate;
  final double? quantity;
  final String? unit;
  final String? referenceId;
  final String? workerId;
  final SyncStatus syncStatus;
  final DateTime? createdAt;
  final int version;
  final int? previousVersion;

  const RevenueModel({
    this.id,
    required this.farmId,
    required this.date,
    required this.category,
    this.description,
    required this.amount,
    this.currency = AppCurrency.dollar,
    this.exchangeRate,
    this.quantity,
    this.unit,
    this.referenceId,
    this.workerId,
    this.syncStatus = SyncStatus.synced,
    this.createdAt,
    this.version = 1,
    this.previousVersion,
  });

  String get currencySymbol => AppCurrency.dollar.symbol;

  factory RevenueModel.fromJson(Map<String, dynamic> json) {
    return RevenueModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      date: DateTime.parse(json['date'] as String),
      category: RevenueCategory.values.firstWhere(
        (e) => e.name == json['category'],
        orElse: () => RevenueCategory.other,
      ),
      description: json['description'] as String?,
      amount: (json['amount'] as num).toDouble(),
      currency: AppCurrency.fromName(json['currency'] as String?),
      exchangeRate: json['exchange_rate'] != null
          ? (json['exchange_rate'] as num).toDouble()
          : null,
      quantity: json['quantity'] != null
          ? (json['quantity'] as num).toDouble()
          : null,
      unit: json['unit'] as String?,
      referenceId: json['reference_id'] as String?,
      workerId: json['worker_id'] as String?,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == json['sync_status'],
        orElse: () => SyncStatus.synced,
      ),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      version: json['version'] as int? ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'farm_id': farmId,
        'date': date.toIso8601String().split('T').first,
        'category': category.name,
        'description': description,
        'amount': amount,
        'currency': currency.name,
        if (exchangeRate != null) 'exchange_rate': exchangeRate,
        if (quantity != null) 'quantity': quantity,
        if (unit != null) 'unit': unit,
        if (referenceId != null) 'reference_id': referenceId,
        if (workerId != null) 'worker_id': workerId,
        'sync_status': syncStatus.name,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
        'version': version,
      };

  RevenueModel copyWith({
    String? id,
    String? farmId,
    DateTime? date,
    RevenueCategory? category,
    String? description,
    double? amount,
    AppCurrency? currency,
    double? exchangeRate,
    double? quantity,
    String? unit,
    String? referenceId,
    String? workerId,
    SyncStatus? syncStatus,
    int? version,
    int? previousVersion,
  }) {
    return RevenueModel(
      id: id ?? this.id,
      farmId: farmId ?? this.farmId,
      date: date ?? this.date,
      category: category ?? this.category,
      description: description ?? this.description,
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      exchangeRate: exchangeRate ?? this.exchangeRate,
      quantity: quantity ?? this.quantity,
      unit: unit ?? this.unit,
      referenceId: referenceId ?? this.referenceId,
      workerId: workerId ?? this.workerId,
      syncStatus: syncStatus ?? this.syncStatus,
      createdAt: createdAt,
      version: version ?? this.version,
      previousVersion: previousVersion ?? this.previousVersion,
    );
  }
}
