import '../constants/enums.dart';
import '../utils/egg_calculator.dart';

/// نموذج تخريج البيض (فاتورة بيع كمية فقط بدون أسعار)
class DispatchModel {
  final String? id;
  final String farmId;
  final DateTime date;
  final String customerId;
  final int cartons;
  final int trays;

  /// وزن الصحن (كغ) — وزن 30 بيضة، اختياري لقياس متوسط حجم البيض
  final double? trayWeightKg;
  final String? notes;
  final PaymentStatus paymentStatus;
  final String workerId;
  final SyncStatus syncStatus;
  final int version;
  final int? previousVersion;

  const DispatchModel({
    this.id,
    required this.farmId,
    required this.date,
    required this.customerId,
    required this.cartons,
    required this.trays,
    this.trayWeightKg,
    this.notes,
    this.paymentStatus = PaymentStatus.unpaid,
    required this.workerId,
    this.syncStatus = SyncStatus.pending,
    this.version = 1,
    this.previousVersion,
  });

  /// وزن البيضة الواحدة بالجرام (وزن الصحن ÷ 30 × 1000)
  double? get avgEggWeightGrams =>
      trayWeightKg == null ? null : trayWeightKg! / 30 * 1000;

  /// الإجمالي بالبيضات (لا يوجد أي مبلغ مالي)
  int get totalEggs =>
      EggCalculator.calculateTotal(cartons: cartons, trays: trays, looseEggs: 0);

  factory DispatchModel.fromJson(Map<String, dynamic> json) {
    return DispatchModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      date: DateTime.parse(json['date'] as String),
      customerId: json['customer_id'] as String,
      cartons: json['cartons'] as int? ?? 0,
      trays: json['trays'] as int? ?? 0,
      trayWeightKg: (json['tray_weight_kg'] as num?)?.toDouble(),
      notes: json['notes'] as String?,
      paymentStatus: PaymentStatus.values.firstWhere(
        (e) => e.name == json['payment_status'],
        orElse: () => PaymentStatus.unpaid,
      ),
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
        'customer_id': customerId,
        'cartons': cartons,
        'trays': trays,
        'total_eggs': totalEggs,
        if (trayWeightKg != null) 'tray_weight_kg': trayWeightKg,
        'notes': notes,
        'payment_status': paymentStatus.name,
        'worker_id': workerId,
        'sync_status': syncStatus.name,
        'version': version,
      };
}