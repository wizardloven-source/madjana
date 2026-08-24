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
      ),
      dueDate: json['due_date'] != null
          ? DateTime.tryParse(json['due_date'] as String)
          : null,
      notes: json['notes'] as String?,
      managerId: json['manager_id'] as String,
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
      };
}