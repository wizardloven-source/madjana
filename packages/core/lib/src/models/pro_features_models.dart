/// نموذج السجل الصحي
class HealthLogModel {
  final String? id;
  final String flockId;
  final String farmId;
  final DateTime logDate;
  final String? symptom;
  final String? diagnosis;
  final String? treatmentAction;
  final String? medicationUsed;
  final String? severity; // LOW, MEDIUM, HIGH, CRITICAL
  final String? vetName;
  final double cost;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  const HealthLogModel({
    this.id,
    required this.flockId,
    required this.farmId,
    required this.logDate,
    this.symptom,
    this.diagnosis,
    this.treatmentAction,
    this.medicationUsed,
    this.severity,
    this.vetName,
    this.cost = 0,
    required this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  factory HealthLogModel.fromJson(Map<String, dynamic> json) {
    return HealthLogModel(
      id: json['id'] as String?,
      flockId: json['flock_id'] as String,
      farmId: json['farm_id'] as String,
      logDate: DateTime.parse(json['log_date'] as String),
      symptom: json['symptom'] as String?,
      diagnosis: json['diagnosis'] as String?,
      treatmentAction: json['treatment_action'] as String?,
      medicationUsed: json['medication_used'] as String?,
      severity: json['severity'] as String?,
      vetName: json['vet_name'] as String?,
      cost: (json['cost'] as num?)?.toDouble() ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['updated_at'] != null 
          ? DateTime.parse(json['updated_at'] as String) 
          : null,
      deletedAt: json['deleted_at'] != null 
          ? DateTime.parse(json['deleted_at'] as String) 
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'flock_id': flockId,
      'farm_id': farmId,
      'log_date': logDate.toIso8601String().split('T')[0], // Date only
      'symptom': symptom,
      'diagnosis': diagnosis,
      'treatment_action': treatmentAction,
      'medication_used': medicationUsed,
      'severity': severity,
      'vet_name': vetName,
      'cost': cost,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
    };
  }

  @override
  String toString() => 'HealthLog(flock: $flockId, date: $logDate, severity: $severity)';
}

/// نموذج وردية العامل
class WorkerShiftModel {
  final String? id;
  final String farmId;
  final String workerName;
  final DateTime shiftDate;
  final DateTime startTime;
  final DateTime? endTime;
  final List<String>? tasksCompleted;
  final int? performanceScore; // 1-5
  final String? notes;
  final DateTime createdAt;

  const WorkerShiftModel({
    this.id,
    required this.farmId,
    required this.workerName,
    required this.shiftDate,
    required this.startTime,
    this.endTime,
    this.tasksCompleted,
    this.performanceScore,
    this.notes,
    required this.createdAt,
  });

  factory WorkerShiftModel.fromJson(Map<String, dynamic> json) {
    final tasksJson = json['tasks_completed'];
    List<String> tasks = [];
    if (tasksJson is List) {
      tasks = tasksJson.map((e) => e.toString()).toList();
    } else if (tasksJson is String) {
      // Handle JSONB string if needed
      try {
        final decoded = tasksJson.replaceAll('"', '').split(',');
        tasks = decoded.where((e) => e.isNotEmpty).toList();
      } catch (_) {}
    }

    return WorkerShiftModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      workerName: json['worker_name'] as String,
      shiftDate: DateTime.parse(json['shift_date'] as String),
      startTime: DateTime.parse(json['start_time'] as String),
      endTime: json['end_time'] != null 
          ? DateTime.parse(json['end_time'] as String) 
          : null,
      tasksCompleted: tasks.isEmpty ? null : tasks,
      performanceScore: json['performance_score'] as int?,
      notes: json['notes'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'farm_id': farmId,
      'worker_name': workerName,
      'shift_date': shiftDate.toIso8601String().split('T')[0],
      'start_time': startTime.toIso8601String(),
      'end_time': endTime?.toIso8601String(),
      'tasks_completed': tasksCompleted,
      'performance_score': performanceScore,
      'notes': notes,
      'created_at': createdAt.toIso8601String(),
    };
  }

  Duration? get duration => endTime != null 
      ? endTime!.difference(startTime) 
      : null;

  @override
  String toString() => 'WorkerShift(worker: $workerName, date: $shiftDate)';
}
