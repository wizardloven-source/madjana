import '../constants/enums.dart';

/// نموذج الدفع/القبض - للمدير فقط
class PaymentModel {
  final String? id;
  final String farmId;
  final String? dispatchId;
  final String customerId;
  final DateTime date;
  final double pricePerCarton;
  final double totalDue;
  final double amountPaid;
  final PaymentMethod paymentMethod;
  final DateTime? dueDate;
  final String? notes;
  final String managerId;
  final AppCurrency currency;
  final double? exchangeRate;
  final SyncStatus syncStatus;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int? version;

  const PaymentModel({
    this.id,
    required this.farmId,
    this.dispatchId,
    required this.customerId,
    required this.date,
    required this.pricePerCarton,
    required this.totalDue,
    required this.amountPaid,
    required this.paymentMethod,
    this.dueDate,
    this.notes,
    required this.managerId,
    this.currency = AppCurrency.dollar,
    this.exchangeRate,
    this.syncStatus = SyncStatus.synced,
    this.createdAt,
    this.updatedAt,
    this.version,
  });

  /// هل المبلغ مسدد بالكامل؟
  bool get isPaid => amountPaid >= totalDue;

  PaymentModel copyWith({
    String? id,
    String? farmId,
    String? dispatchId,
    String? customerId,
    DateTime? date,
    double? pricePerCarton,
    double? totalDue,
    double? amountPaid,
    PaymentMethod? paymentMethod,
    DateTime? dueDate,
    String? notes,
    String? managerId,
    AppCurrency? currency,
    double? exchangeRate,
    SyncStatus? syncStatus,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? version,
  }) {
    return PaymentModel(
      id: id ?? this.id,
      farmId: farmId ?? this.farmId,
      dispatchId: dispatchId ?? this.dispatchId,
      customerId: customerId ?? this.customerId,
      date: date ?? this.date,
      pricePerCarton: pricePerCarton ?? this.pricePerCarton,
      totalDue: totalDue ?? this.totalDue,
      amountPaid: amountPaid ?? this.amountPaid,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      dueDate: dueDate ?? this.dueDate,
      notes: notes ?? this.notes,
      managerId: managerId ?? this.managerId,
      currency: currency ?? this.currency,
      exchangeRate: exchangeRate ?? this.exchangeRate,
      syncStatus: syncStatus ?? this.syncStatus,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
    );
  }

  /// عرض رمز العملة (الدولار هو الأساسي دائماً)
  String get currencySymbol => AppCurrency.dollar.symbol;

  factory PaymentModel.fromJson(Map<String, dynamic> json) {
    return PaymentModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      dispatchId: json['dispatch_id'] as String?,
      customerId: json['customer_id'] as String,
      date: DateTime.parse(json['date'] as String),
      pricePerCarton: (json['price_per_carton'] as num).toDouble(),
      totalDue: (json['total_due'] as num).toDouble(),
      amountPaid: (json['amount_paid'] as num).toDouble(),
      paymentMethod: PaymentMethod.values.firstWhere(
        (e) => e.name == json['payment_method'],
        orElse: () => PaymentMethod.cash,
      ),
      dueDate: json['due_date'] != null
          ? DateTime.tryParse(json['due_date'] as String)
          : null,
      notes: json['notes'] as String?,
      managerId: json['manager_id'] as String,
      currency: AppCurrency.fromName(json['currency'] as String?),
      exchangeRate: json['exchange_rate'] != null
          ? (json['exchange_rate'] as num).toDouble()
          : null,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == (json['sync_status'] ?? 'synced'),
        orElse: () => SyncStatus.synced,
      ),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)
          : null,
      version: json['version'] != null
          ? (json['version'] as num).toInt()
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'farm_id': farmId,
        'dispatch_id': dispatchId,
        'customer_id': customerId,
        'date': date.toIso8601String().split('T').first,
        'price_per_carton': pricePerCarton,
        'total_due': totalDue,
        'amount_paid': amountPaid,
        'payment_method': paymentMethod.name,
        'due_date': dueDate?.toIso8601String().split('T').first,
        'notes': notes,
        'manager_id': managerId,
        'currency': currency.name,
        if (exchangeRate != null) 'exchange_rate': exchangeRate,
        if (syncStatus != SyncStatus.synced) 'sync_status': syncStatus.name,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
        if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
        if (version != null) 'version': version,
      };
}