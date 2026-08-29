import 'package:core/core.dart';

/// نموذج عنصر المخزون
class InventoryItemModel extends Entity {
  final String? id;
  final String farmId;
  final String name;
  final String category; // feed, medicine, equipment
  final String? barcode;
  final double quantity;
  final String unit; // kg, box, liter
  final double minStockLevel;
  final DateTime? expiryDate;
  final String? locationBin;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  const InventoryItemModel({
    this.id,
    required this.farmId,
    required this.name,
    required this.category,
    this.barcode,
    this.quantity = 0,
    required this.unit,
    this.minStockLevel = 0,
    this.expiryDate,
    this.locationBin,
    required this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  factory InventoryItemModel.fromJson(Map<String, dynamic> json) {
    return InventoryItemModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      name: json['name'] as String,
      category: json['category'] as String,
      barcode: json['barcode'] as String?,
      quantity: (json['quantity'] as num).toDouble(),
      unit: json['unit'] as String,
      minStockLevel: (json['min_stock_level'] as num?)?.toDouble() ?? 0,
      expiryDate: json['expiry_date'] != null 
          ? DateTime.parse(json['expiry_date'] as String) 
          : null,
      locationBin: json['location_bin'] as String?,
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
      'farm_id': farmId,
      'name': name,
      'category': category,
      'barcode': barcode,
      'quantity': quantity,
      'unit': unit,
      'min_stock_level': minStockLevel,
      'expiry_date': expiryDate?.toIso8601String(),
      'location_bin': locationBin,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
    };
  }

  bool get isLowStock => quantity <= minStockLevel;
  bool get isExpired => expiryDate != null && expiryDate!.isBefore(DateTime.now());

  @override
  String toString() => 'InventoryItem(id: $id, name: $name, qty: $quantity $unit)';
}

/// نموذج حركة المخزون
class InventoryTransactionModel extends Entity {
  final String? id;
  final String itemId;
  final String farmId;
  final String transactionType; // IN, OUT, ADJUSTMENT
  final double quantity;
  final String? reason;
  final String? performedBy;
  final DateTime createdAt;

  const InventoryTransactionModel({
    this.id,
    required this.itemId,
    required this.farmId,
    required this.transactionType,
    required this.quantity,
    this.reason,
    this.performedBy,
    required this.createdAt,
  });

  factory InventoryTransactionModel.fromJson(Map<String, dynamic> json) {
    return InventoryTransactionModel(
      id: json['id'] as String?,
      itemId: json['item_id'] as String,
      farmId: json['farm_id'] as String,
      transactionType: json['transaction_type'] as String,
      quantity: (json['quantity'] as num).toDouble(),
      reason: json['reason'] as String?,
      performedBy: json['performed_by'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'item_id': itemId,
      'farm_id': farmId,
      'transaction_type': transactionType,
      'quantity': quantity,
      'reason': reason,
      'performed_by': performedBy,
      'created_at': createdAt.toIso8601String(),
    };
  }

  @override
  String toString() => 'InventoryTransaction(type: $transactionType, qty: $quantity)';
}

/// نموذج السجل الصحي
class HealthLogModel extends Entity {
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
class WorkerShiftModel extends Entity {
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
        final decoded = (tasksJson as String).replaceAll('"', '').split(',');
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
