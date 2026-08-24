import '../constants/enums.dart';

/// نموذج القطيع
class FlockModel {
  final String id;
  final String farmId;
  final String breed;
  final DateTime startDate;
  final int initialCount;
  final int currentCount;
  final FlockStatus status;

  /// عدد العنابر في المدجنة (1..3)
  final int sectionsCount;

  const FlockModel({
    required this.id,
    required this.farmId,
    required this.breed,
    required this.startDate,
    required this.initialCount,
    required this.currentCount,
    this.status = FlockStatus.active,
    this.sectionsCount = 1,
  });

  /// نسبة الإنتاج المتوقعة اليومية
  double get productionRate =>
      currentCount == 0 ? 0 : (1 / currentCount) * 100;

  factory FlockModel.fromJson(Map<String, dynamic> json) {
    return FlockModel(
      id: json['id'] as String,
      farmId: json['farm_id'] as String,
      breed: json['breed'] as String,
      startDate: DateTime.parse(json['start_date'] as String),
      initialCount: json['initial_count'] as int,
      currentCount: json['current_count'] as int,
      status: FlockStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => FlockStatus.active,
      ),
      sectionsCount: json['sections_count'] as int? ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'farm_id': farmId,
        'breed': breed,
        'start_date': startDate.toIso8601String().split('T').first,
        'initial_count': initialCount,
        'current_count': currentCount,
        'status': status.name,
        'sections_count': sectionsCount,
      };

  /// اسم مختصر للعرض
  String get displayName => '$breed (${currentCount} طائر)';
}