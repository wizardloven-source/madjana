import '../constants/enums.dart';
import '../utils/egg_calculator.dart';

/// نموذج إنتاج البيض اليومي
class EggProductionModel {
  final String? id;
  final String farmId;
  final String flockId;
  final DateTime date;
  final int cartons;
  final int trays;
  final int looseEggs;
  final int brokenEggs;
  final int dirtyEggs;
  final double? trayWeightKg;
  final String workerId;
  final SyncStatus syncStatus;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// رقم العنبر داخل المدجنة (1..sections_count) — اختياري
  final int? sectionNo;

  /// إصدار السجل (version-based conflict detection)
  final int version;

  /// الإصدار السابق عند التزامن (يُستخدم فقط عند الإرسال، لا يُخزن في قاعدة البيانات)
  final int? previousVersion;

  const EggProductionModel({
    this.id,
    required this.farmId,
    required this.flockId,
    required this.date,
    required this.cartons,
    required this.trays,
    required this.looseEggs,
    this.brokenEggs = 0,
    this.dirtyEggs = 0,
    this.trayWeightKg,
    required this.workerId,
    this.syncStatus = SyncStatus.pending,
    this.createdAt,
    this.updatedAt,
    this.sectionNo,
    this.version = 1,
    this.previousVersion,
  });

  /// الإجمالي محسوب تلقائياً
  int get totalEggs => EggCalculator.calculateTotal(
        cartons: cartons,
        trays: trays,
        looseEggs: looseEggs,
      );

  /// التحقق من صحة البيانات
  bool get isValid {
    if (totalEggs == 0) return false;
    if (brokenEggs + dirtyEggs > totalEggs) return false;
    if (date.isAfter(DateTime.now())) return false;
    return true;
  }

  factory EggProductionModel.fromJson(Map<String, dynamic> json) {
    return EggProductionModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      flockId: json['flock_id'] as String,
      date: DateTime.parse(json['date'] as String),
      cartons: json['cartons'] as int? ?? 0,
      trays: json['trays'] as int? ?? 0,
      looseEggs: json['loose_eggs'] as int? ?? 0,
      brokenEggs: json['broken_eggs'] as int? ?? 0,
      dirtyEggs: json['dirty_eggs'] as int? ?? 0,
      trayWeightKg: (json['tray_weight_kg'] as num?)?.toDouble(),
      sectionNo: json['section_no'] as int?,
      workerId: json['worker_id'] as String,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == json['sync_status'],
        orElse: () => SyncStatus.pending,
      ),
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : null,
      version: json['version'] as int? ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'farm_id': farmId,
        'flock_id': flockId,
        'date': date.toIso8601String().split('T').first,
        'cartons': cartons,
        'trays': trays,
        'loose_eggs': looseEggs,
        'total_eggs': totalEggs,
        'broken_eggs': brokenEggs,
        'dirty_eggs': dirtyEggs,
        'tray_weight_kg': trayWeightKg,
        if (sectionNo != null) 'section_no': sectionNo,
        'worker_id': workerId,
        'sync_status': syncStatus.name,
        'version': version,
      };

  EggProductionModel copyWith({
    String? id,
    int? cartons,
    int? trays,
    int? looseEggs,
    int? brokenEggs,
    int? dirtyEggs,
    double? trayWeightKg,
    int? sectionNo,
    DateTime? createdAt,
    DateTime? updatedAt,
    SyncStatus? syncStatus,
    int? version,
    int? previousVersion,
  }) {
    return EggProductionModel(
      id: id ?? this.id,
      farmId: farmId,
      flockId: flockId,
      date: date,
      cartons: cartons ?? this.cartons,
      trays: trays ?? this.trays,
      looseEggs: looseEggs ?? this.looseEggs,
      brokenEggs: brokenEggs ?? this.brokenEggs,
      dirtyEggs: dirtyEggs ?? this.dirtyEggs,
      trayWeightKg: trayWeightKg ?? this.trayWeightKg,
      sectionNo: sectionNo ?? this.sectionNo,
      workerId: workerId,
      syncStatus: syncStatus ?? this.syncStatus,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      previousVersion: previousVersion ?? this.previousVersion,
    );
  }
}