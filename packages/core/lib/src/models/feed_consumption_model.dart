import '../constants/app_constants.dart';
import '../constants/enums.dart';

/// نموذج استهلاك العلف اليومي
class FeedConsumptionModel {
  final String? id;
  final String farmId;
  final DateTime date;
  final FeedEntryMode entryMode;
  final int bagsCount;
  final double quantityKg;
  final String workerId;
  final SyncStatus syncStatus;

  const FeedConsumptionModel({
    this.id,
    required this.farmId,
    required this.date,
    required this.entryMode,
    this.bagsCount = 0,
    required this.quantityKg,
    required this.workerId,
    this.syncStatus = SyncStatus.pending,
  });

  /// حساب الكمية بالكيلو من عدد الأكياس
  factory FeedConsumptionModel.fromBags({
    required String farmId,
    required DateTime date,
    required int bags,
    required String workerId,
  }) {
    return FeedConsumptionModel(
      farmId: farmId,
      date: date,
      entryMode: FeedEntryMode.bags,
      bagsCount: bags,
      quantityKg: bags * AppConstants.kgPerBag,
      workerId: workerId,
    );
  }

  bool get isValid => quantityKg > 0;

  factory FeedConsumptionModel.fromJson(Map<String, dynamic> json) {
    return FeedConsumptionModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      date: DateTime.parse(json['date'] as String),
      entryMode: FeedEntryMode.values.firstWhere(
        (e) => e.name == json['entry_mode'],
        orElse: () => FeedEntryMode.bags,
      ),
      bagsCount: json['bags_count'] as int? ?? 0,
      quantityKg: (json['quantity_kg'] as num).toDouble(),
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
        'date': date.toIso8601String().split('T').first,
        'entry_mode': entryMode.name,
        'bags_count': bagsCount,
        'quantity_kg': quantityKg,
        'worker_id': workerId,
        'sync_status': syncStatus.name,
      };
}