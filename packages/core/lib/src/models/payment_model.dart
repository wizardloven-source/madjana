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
  final SyncStatus syncStatus;
  final DateTime? createdAt;
  final DateTime? updatedAt;

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
    this.syncStatus = SyncStatus.synced,
    this.createdAt,
    this.updatedAt,
  });

  /// هل المبلغ مسدد بالكامل؟
  bool get isPaid => amountPaid >= totalDue;

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
        if (syncStatus != SyncStatus.synced) 'sync_status': syncStatus.name,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
        if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
      };
}