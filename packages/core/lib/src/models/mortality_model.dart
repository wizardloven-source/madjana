import '../constants/enums.dart';

/// نموذج سجل النفوق
class MortalityModel {
  final String? id;
  final String farmId;
  final String flockId;
  final DateTime date;
  final int count;
  final MortalityReason reason;
  final String? reasonOther;
  final String? notes;
  final String? imageUrl;
  final String workerId;
  final SyncStatus syncStatus;

  const MortalityModel({
    this.id,
    required this.farmId,
    required this.flockId,
    required this.date,
    required this.count,
    required this.reason,
    this.reasonOther,
    this.notes,
    this.imageUrl,
    required this.workerId,
    this.syncStatus = SyncStatus.pending,
  });

  bool get isValid => count > 0 && date.isBefore(DateTime.now().add(const Duration(days: 1)));

  factory MortalityModel.fromJson(Map<String, dynamic> json) {
    return MortalityModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      flockId: json['flock_id'] as String,
      date: DateTime.parse(json['date'] as String),
      count: json['count'] as int,
      reason: MortalityReason.values.firstWhere(
        (e) => e.name == json['reason'],
      ),
      reasonOther: json['reason_other'] as String?,
      notes: json['notes'] as String?,
      imageUrl: json['image_url'] as String?,
      workerId: json['worker_id'] as String,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == json['sync_status'],
        orElse: () => SyncStatus.pending,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'farm_id': farmId,
        'flock_id': flockId,
        'date': date.toIso8601String().split('T').first,
        'count': count,
        'reason': reason.name,
        'reason_other': reasonOther,
        'notes': notes,
        'image_url': imageUrl,
        'worker_id': workerId,
        'sync_status': syncStatus.name,
      };
}