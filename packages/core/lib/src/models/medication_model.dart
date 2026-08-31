import '../constants/enums.dart';

/// نموذج سجل دوائي
class MedicationModel {
  final String? id;
  final String farmId;
  final DateTime date;
  final MedicationType type;
  final String medicineName;
  final String dosage;
  final AdministrationRoute administrationRoute;
  final int? treatmentDays;
  final int withdrawalDays;
  final String? notes;
  final String workerId;
  final SyncStatus syncStatus;
  final int version;
  final int? previousVersion;

  const MedicationModel({
    this.id,
    required this.farmId,
    required this.date,
    required this.type,
    required this.medicineName,
    required this.dosage,
    required this.administrationRoute,
    this.treatmentDays,
    this.withdrawalDays = 0,
    this.notes,
    required this.workerId,
    this.syncStatus = SyncStatus.pending,
    this.version = 1,
    this.previousVersion,
  });

  factory MedicationModel.fromJson(Map<String, dynamic> json) {
    return MedicationModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      date: DateTime.parse(json['date'] as String),
      type: MedicationType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => MedicationType.drug,
      ),
      medicineName: json['medicine_name'] as String,
      dosage: json['dosage'] as String,
      administrationRoute: AdministrationRoute.values.firstWhere(
        (e) => e.name == json['administration_route'],
        orElse: () => AdministrationRoute.water,
      ),
      treatmentDays: json['treatment_days'] as int?,
      withdrawalDays: json['withdrawal_days'] as int? ?? 0,
      notes: json['notes'] as String?,
      workerId: json['worker_id'] as String,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == json['sync_status'],
        orElse: () => SyncStatus.pending,
      ),
      version: json['version'] as int? ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'farm_id': farmId,
        'date': date.toIso8601String().split('T').first,
        'type': type.name,
        'medicine_name': medicineName,
        'dosage': dosage,
        'administration_route': administrationRoute.name,
        'treatment_days': treatmentDays,
        'withdrawal_days': withdrawalDays,
        'notes': notes,
        'worker_id': workerId,
        'sync_status': syncStatus.name,
        'version': version,
      };
}