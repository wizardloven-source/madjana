/// نموذج الزبون
class CustomerModel {
  final String? id;
  final String farmId;
  final String name;
  final String phone;
  final String? notes;
  final double totalDebt;

  const CustomerModel({
    this.id,
    required this.farmId,
    required this.name,
    required this.phone,
    this.notes,
    this.totalDebt = 0,
  });

  factory CustomerModel.fromJson(Map<String, dynamic> json) {
    return CustomerModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      name: json['name'] as String,
      phone: json['phone'] as String,
      notes: json['notes'] as String?,
      totalDebt: (json['total_debt'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'farm_id': farmId,
        'name': name,
        'phone': phone,
        'notes': notes,
        'total_debt': totalDebt,
      };
}