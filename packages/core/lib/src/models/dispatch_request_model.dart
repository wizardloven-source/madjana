/// نموذج طلب التخريج
class DispatchRequestModel {
  final String? id;
  final String farmId;
  final String customerId;
  final int requestedCartons;
  final int requestedTrays;
  final String? notes;
  final String status;
  final DateTime createdAt;
  final DateTime? updatedAt;

  const DispatchRequestModel({
    this.id,
    required this.farmId,
    required this.customerId,
    required this.requestedCartons,
    required this.requestedTrays,
    this.notes,
    this.status = 'pending',
    required this.createdAt,
    this.updatedAt,
  });

  factory DispatchRequestModel.fromJson(Map<String, dynamic> json) {
    return DispatchRequestModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      customerId: json['customer_id'] as String,
      requestedCartons: json['requested_cartons'] as int? ?? 0,
      requestedTrays: json['requested_trays'] as int? ?? 0,
      notes: json['notes'] as String?,
      status: json['status'] as String? ?? 'pending',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'].toString())
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'farm_id': farmId,
        'customer_id': customerId,
        'requested_cartons': requestedCartons,
        'requested_trays': requestedTrays,
        'notes': notes,
        'status': status,
        'created_at': createdAt.toIso8601String(),
        if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
      };
}
