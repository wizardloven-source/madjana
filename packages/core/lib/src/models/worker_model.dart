import '../constants/enums.dart';

/// نموذج العامل المرتبط بمدجنة
class WorkerModel {
  final String id;
  final String name;
  final String phone;
  final String? farmId; // المدجنة الرئيسية
  final List<String> assignedFlockIds; // قائمة معرفات القطعان المرتبطة بالعامل
  final double baseSalary; // الراتب الأساسي الشهري
  final DateTime hireDate;
  final bool isActive;
  final DateTime createdAt;

  const WorkerModel({
    required this.id,
    required this.name,
    required this.phone,
    this.farmId,
    this.assignedFlockIds = const [],
    this.baseSalary = 0.0,
    required this.hireDate,
    this.isActive = true,
    required this.createdAt,
  });

  factory WorkerModel.fromJson(Map<String, dynamic> json) {
    return WorkerModel(
      id: json['id'] as String,
      name: json['name'] as String,
      phone: json['phone'] as String,
      farmId: json['farm_id'] as String?,
      assignedFlockIds: (json['assigned_flock_ids'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
      baseSalary: (json['base_salary'] as num?)?.toDouble() ?? 0.0,
      hireDate: json['hire_date'] != null 
          ? DateTime.parse(json['hire_date'] as String) 
          : DateTime.now(),
      isActive: json['is_active'] as bool? ?? true,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'].toString())
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'farm_id': farmId,
        'assigned_flock_ids': assignedFlockIds,
        'base_salary': baseSalary,
        'hire_date': hireDate.toIso8601String().split('T').first,
        'is_active': isActive,
        'created_at': createdAt.toIso8601String(),
      };

  WorkerModel copyWith({
    String? name,
    String? phone,
    String? farmId,
    List<String>? assignedFlockIds,
    double? baseSalary,
    DateTime? hireDate,
    bool? isActive,
  }) {
    return WorkerModel(
      id: id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      farmId: farmId ?? this.farmId,
      assignedFlockIds: assignedFlockIds ?? this.assignedFlockIds,
      baseSalary: baseSalary ?? this.baseSalary,
      hireDate: hireDate ?? this.hireDate,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
    );
  }

  /// إجمالي الراتب من جميع المداجن
  double get totalSalary => baseSalary;

  /// عدد المداجن المرتبطة
  int get assignedFlocksCount => assignedFlockIds.length;
}

/// نموذج كشف الراتب الشهري للعامل
class SalarySlipModel {
  final String id;
  final String workerId;
  final String workerName;
  final int year;
  final int month; // 1-12
  final double baseSalary; // الراتب الأساسي
  final double advances; // السلف المسحوبة
  final double bonuses; // المكافآت
  final double deductions; // الخصومات
  final double netSalary; // الصافي
  final bool isPaid; // هل تم الصرف
  final DateTime paidAt; // تاريخ الصرف
  final String? notes;
  final DateTime createdAt;

  const SalarySlipModel({
    required this.id,
    required this.workerId,
    required this.workerName,
    required this.year,
    required this.month,
    required this.baseSalary,
    this.advances = 0.0,
    this.bonuses = 0.0,
    this.deductions = 0.0,
    required this.netSalary,
    this.isPaid = false,
    DateTime? paidAt,
    this.notes,
    required this.createdAt,
  }) : paidAt = paidAt ?? DateTime.now();

  factory SalarySlipModel.fromJson(Map<String, dynamic> json) {
    return SalarySlipModel(
      id: json['id'] as String,
      workerId: json['worker_id'] as String,
      workerName: json['worker_name'] as String,
      year: json['year'] as int,
      month: json['month'] as int,
      baseSalary: (json['base_salary'] as num).toDouble(),
      advances: (json['advances'] as num?)?.toDouble() ?? 0.0,
      bonuses: (json['bonuses'] as num?)?.toDouble() ?? 0.0,
      deductions: (json['deductions'] as num?)?.toDouble() ?? 0.0,
      netSalary: (json['net_salary'] as num).toDouble(),
      isPaid: json['is_paid'] as bool? ?? false,
      paidAt: json['paid_at'] != null
          ? DateTime.parse(json['paid_at'] as String)
          : null,
      notes: json['notes'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'].toString())
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'worker_id': workerId,
        'worker_name': workerName,
        'year': year,
        'month': month,
        'base_salary': baseSalary,
        'advances': advances,
        'bonuses': bonuses,
        'deductions': deductions,
        'net_salary': netSalary,
        'is_paid': isPaid,
        'paid_at': isPaid ? paidAt.toIso8601String() : null,
        'notes': notes,
        'created_at': createdAt.toIso8601String(),
      };

  SalarySlipModel copyWith({
    double? advances,
    double? bonuses,
    double? deductions,
    double? netSalary,
    bool? isPaid,
    DateTime? paidAt,
    String? notes,
  }) {
    return SalarySlipModel(
      id: id,
      workerId: workerId,
      workerName: workerName,
      year: year,
      month: month,
      baseSalary: baseSalary,
      advances: advances ?? this.advances,
      bonuses: bonuses ?? this.bonuses,
      deductions: deductions ?? this.deductions,
      netSalary: netSalary ?? this.netSalary,
      isPaid: isPaid ?? this.isPaid,
      paidAt: paidAt ?? this.paidAt,
      notes: notes ?? this.notes,
      createdAt: createdAt,
    );
  }

  /// إنشاء كشف راتب تلقائي
  static SalarySlipModel create({
    required String workerId,
    required String workerName,
    required int year,
    required int month,
    required double baseSalary,
    double advances = 0.0,
    double bonuses = 0.0,
    double deductions = 0.0,
  }) {
    final netSalary = baseSalary + bonuses - advances - deductions;
    return SalarySlipModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      workerId: workerId,
      workerName: workerName,
      year: year,
      month: month,
      baseSalary: baseSalary,
      advances: advances,
      bonuses: bonuses,
      deductions: deductions,
      netSalary: netSalary,
      isPaid: false,
      createdAt: DateTime.now(),
    );
  }
}

/// نموذج طلب السلفة
class AdvanceRequestModel {
  final String id;
  final String workerId;
  final String workerName;
  final double amount;
  final String reason;
  final DateTime requestDate;
  final AdvanceRequestStatus status;
  final String? managerNotes;
  final DateTime? reviewedAt;
  final DateTime createdAt;

  const AdvanceRequestModel({
    required this.id,
    required this.workerId,
    required this.workerName,
    required this.amount,
    required this.reason,
    required this.requestDate,
    this.status = AdvanceRequestStatus.pending,
    this.managerNotes,
    this.reviewedAt,
    required this.createdAt,
  });

  factory AdvanceRequestModel.fromJson(Map<String, dynamic> json) {
    return AdvanceRequestModel(
      id: json['id'] as String,
      workerId: json['worker_id'] as String,
      workerName: json['worker_name'] as String,
      amount: (json['amount'] as num).toDouble(),
      reason: json['reason'] as String,
      requestDate: DateTime.parse(json['request_date'] as String),
      status: AdvanceRequestStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => AdvanceRequestStatus.pending,
      ),
      managerNotes: json['manager_notes'] as String?,
      reviewedAt: json['reviewed_at'] != null
          ? DateTime.parse(json['reviewed_at'] as String)
          : null,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'].toString())
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'worker_id': workerId,
        'worker_name': workerName,
        'amount': amount,
        'reason': reason,
        'request_date': requestDate.toIso8601String(),
        'status': status.name,
        'manager_notes': managerNotes,
        'reviewed_at': reviewedAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
      };

  AdvanceRequestModel copyWith({
    AdvanceRequestStatus? status,
    String? managerNotes,
    DateTime? reviewedAt,
  }) {
    return AdvanceRequestModel(
      id: id,
      workerId: workerId,
      workerName: workerName,
      amount: amount,
      reason: reason,
      requestDate: requestDate,
      status: status ?? this.status,
      managerNotes: managerNotes ?? this.managerNotes,
      reviewedAt: reviewedAt ?? this.reviewedAt,
      createdAt: createdAt,
    );
  }
}

/// حالة طلب السلفة
enum AdvanceRequestStatus {
  pending, // قيد الانتظار
  approved, // موافق عليه
  rejected, // مرفوض
  paid; // تم الصرف

  String get label {
    switch (this) {
      case AdvanceRequestStatus.pending:
        return 'قيد الانتظار';
      case AdvanceRequestStatus.approved:
        return 'موافق عليه';
      case AdvanceRequestStatus.rejected:
        return 'مرفوض';
      case AdvanceRequestStatus.paid:
        return 'تم الصرف';
    }
  }
}
