import '../constants/enums.dart';

/// نموذج دواء من كتالوج الأدوية
class MedicineModel {
  final String id;
  final String name;
  final MedicationType type;
  final int withdrawalDays;
  final String? notes;

  const MedicineModel({
    required this.id,
    required this.name,
    required this.type,
    this.withdrawalDays = 0,
    this.notes,
  });

  factory MedicineModel.fromJson(Map<String, dynamic> json) {
    return MedicineModel(
      id: json['id'] as String,
      name: json['name'] as String,
      type: MedicationType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => MedicationType.drug,
      ),
      withdrawalDays: json['withdrawal_days'] as int? ?? 0,
      notes: json['notes'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'withdrawal_days': withdrawalDays,
        'notes': notes,
      };
}