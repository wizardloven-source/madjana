import '../constants/enums.dart';

/// عنصر مخزون (أدوية/مستلزمات) - للمدير
class InventoryItemModel {
  final String? id;
  final String farmId;
  final String name;
  final InventoryUnit unit;
  final double quantity;
  final double lowStockThreshold;
  final String? notes;
  final DateTime? updatedAt;

  const InventoryItemModel({
    this.id,
    required this.farmId,
    required this.name,
    this.unit = InventoryUnit.piece,
    this.quantity = 0,
    this.lowStockThreshold = 5,
    this.notes,
    this.updatedAt,
  });

  /// هل الكمية منخفضة؟
  bool get isLowStock => quantity <= lowStockThreshold;

  factory InventoryItemModel.fromJson(Map<String, dynamic> json) {
    return InventoryItemModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      name: json['name'] as String,
      unit: InventoryUnit.values.firstWhere(
        (e) => e.name == json['unit'],
        orElse: () => InventoryUnit.piece,
      ),
      quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
      lowStockThreshold:
          (json['low_stock_threshold'] as num?)?.toDouble() ?? 5,
      notes: json['notes'] as String?,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'farm_id': farmId,
        'name': name,
        'unit': unit.name,
        'quantity': quantity,
        'low_stock_threshold': lowStockThreshold,
        'notes': notes,
      };

  InventoryItemModel copyWith({
    String? id,
    String? farmId,
    String? name,
    InventoryUnit? unit,
    double? quantity,
    double? lowStockThreshold,
    String? notes,
  }) {
    return InventoryItemModel(
      id: id ?? this.id,
      farmId: farmId ?? this.farmId,
      name: name ?? this.name,
      unit: unit ?? this.unit,
      quantity: quantity ?? this.quantity,
      lowStockThreshold: lowStockThreshold ?? this.lowStockThreshold,
      notes: notes ?? this.notes,
      updatedAt: updatedAt,
    );
  }
}

/// حركة مخزون (إدخال / إخراج)
class InventoryTransactionModel {
  final String? id;
  final String itemId;
  final DateTime date;
  final bool isInput;
  final double quantity;
  final String? note;
  final String? userId;

  const InventoryTransactionModel({
    this.id,
    required this.itemId,
    required this.date,
    required this.isInput,
    required this.quantity,
    this.note,
    this.userId,
  });

  factory InventoryTransactionModel.fromJson(Map<String, dynamic> json) {
    return InventoryTransactionModel(
      id: json['id'] as String?,
      itemId: json['item_id'] as String,
      date: DateTime.parse(json['date'] as String),
      isInput: json['type'] == 'in',
      quantity: (json['quantity'] as num).toDouble(),
      note: json['note'] as String?,
      userId: json['user_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'item_id': itemId,
        'date': date.toIso8601String(),
        'type': isInput ? 'in' : 'out',
        'quantity': quantity,
        'note': note,
        if (userId != null) 'user_id': userId,
      };
}
