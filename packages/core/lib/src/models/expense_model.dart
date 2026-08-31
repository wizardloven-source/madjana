import '../constants/enums.dart';

/// نموذج المصروف - للمدير فقط
class ExpenseModel {
  final String? id;
  final String farmId;
  final DateTime date;
  final ExpenseCategory category;
  final String? description;
  final double amount;
  final SyncStatus syncStatus;
  final DateTime? createdAt;
  final int version;
  final int? previousVersion;

  const ExpenseModel({
    this.id,
    required this.farmId,
    required this.date,
    required this.category,
    this.description,
    required this.amount,
    this.syncStatus = SyncStatus.synced,
    this.createdAt,
    this.version = 1,
    this.previousVersion,
  });

  factory ExpenseModel.fromJson(Map<String, dynamic> json) {
    return ExpenseModel(
      id: json['id'] as String?,
      farmId: json['farm_id'] as String,
      date: DateTime.parse(json['date'] as String),
      category: ExpenseCategory.values.firstWhere(
        (e) => e.name == json['category'],
        orElse: () => ExpenseCategory.other,
      ),
      description: json['description'] as String?,
      amount: (json['amount'] as num).toDouble(),
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == json['sync_status'],
        orElse: () => SyncStatus.synced,
      ),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      version: json['version'] as int? ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'farm_id': farmId,
        'date': date.toIso8601String().split('T').first,
        'category': category.name,
        'description': description,
        'amount': amount,
        'sync_status': syncStatus.name,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
        'version': version,
      };

  ExpenseModel copyWith({
    String? id,
    String? farmId,
    DateTime? date,
    ExpenseCategory? category,
    String? description,
    double? amount,
    SyncStatus? syncStatus,
    int? version,
    int? previousVersion,
  }) {
    return ExpenseModel(
      id: id ?? this.id,
      farmId: farmId ?? this.farmId,
      date: date ?? this.date,
      category: category ?? this.category,
      description: description ?? this.description,
      amount: amount ?? this.amount,
      syncStatus: syncStatus ?? this.syncStatus,
      createdAt: createdAt,
      version: version ?? this.version,
      previousVersion: previousVersion ?? this.previousVersion,
    );
  }
}
