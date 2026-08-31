import '../constants/enums.dart';

/// نموذج استلام علف
class FeedReceivedModel {
  final String? id;
  final String farmId;
  final DateTime date;
  final FeedEntryMode entryMode;
  final double quantity;
  final double quantityKg;
  final FeedType feedType;
  final String? supplier;
  final String? invoiceNumber;
  final String? notes;

  /// سعر الكيلوغرام — يُدخله المدير لاحقاً من سطح المكتب
  final double? pricePerKg;
  final int? sectionNo;
  final int version;
  final int? previousVersion;

  const FeedReceivedModel({
    this.id,
    required this.farmId,
    required this.date,
    required this.entryMode,
    required this.quantity,
    required this.quantityKg,
    required this.feedType,
    this.supplier,
    this.invoiceNumber,
    this.notes,
    this.pricePerKg,
    this.sectionNo,
    this.version = 1,
    this.previousVersion,
  });

  /// إجمالي قيمة الفاتورة (يُحسب عند التسعير)
  double? get totalPrice =>
      pricePerKg == null ? null : pricePerKg! * quantityKg;

  factory FeedReceivedModel.fromJson(Map<String, dynamic> json) {
    return FeedReceivedModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      date: DateTime.parse(json['date'] as String),
      entryMode: FeedEntryMode.values.firstWhere(
        (e) => e.name == json['entry_mode'],
        orElse: () => FeedEntryMode.bags,
      ),
      quantity: (json['quantity'] as num).toDouble(),
      quantityKg: (json['quantity_kg'] as num).toDouble(),
      feedType: FeedType.values.firstWhere(
        (e) => e.name == json['feed_type'],
        orElse: () => FeedType.main,
      ),
      supplier: json['supplier'] as String?,
      invoiceNumber: json['invoice_number'] as String?,
      notes: json['notes'] as String?,
      pricePerKg: (json['price_per_kg'] as num?)?.toDouble(),
      sectionNo: json['section_no'] as int?,
      version: json['version'] as int? ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'farm_id': farmId,
        'date': date.toIso8601String().split('T').first,
        'entry_mode': entryMode.name,
        'quantity': quantity,
        'quantity_kg': quantityKg,
        'feed_type': feedType.name,
        'supplier': supplier,
        'invoice_number': invoiceNumber,
        'notes': notes,
        'worker_id': '',
        if (sectionNo != null) 'section_no': sectionNo,
        if (pricePerKg != null) 'price_per_kg': pricePerKg,
        'version': version,
      };
}