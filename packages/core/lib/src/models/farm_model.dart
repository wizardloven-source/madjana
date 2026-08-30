/// نموذج المدجنة
class FarmModel {
  final String id;
  final String name;
  final String? location;
  final String? ownerId;
  final DateTime? createdAt;
  // إعدادات النظام
  final double feedBagWeightKg;      // وزن كيس العلف بالكيلو
  final int eggsPerCarton;           // عدد البيض في الكرتون
  final int eggsPerTray;             // عدد البيض في الصينية
  final double defaultMortalityRate; // معدل النفوق الافتراضي (%)

  const FarmModel({
    required this.id,
    required this.name,
    this.location,
    this.ownerId,
    this.createdAt,
    this.feedBagWeightKg = 50.0,     // افتراضي: 50 كغ
    this.eggsPerCarton = 360,        // افتراضي: 360 بيضة
    this.eggsPerTray = 30,           // افتراضي: 30 بيضة
    this.defaultMortalityRate = 0.0, // افتراضي: 0%
  });

  factory FarmModel.fromJson(Map<String, dynamic> json) {
    return FarmModel(
      id: json['id'] as String,
      name: json['name'] as String,
      location: json['location'] as String?,
      ownerId: json['owner_id'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      feedBagWeightKg: (json['feed_bag_weight_kg'] ?? 50.0).toDouble(),
      eggsPerCarton: json['eggs_per_carton'] ?? 360,
      eggsPerTray: json['eggs_per_tray'] ?? 30,
      defaultMortalityRate: (json['default_mortality_rate'] ?? 0.0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'location': location,
        'owner_id': ownerId,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
        'feed_bag_weight_kg': feedBagWeightKg,
        'eggs_per_carton': eggsPerCarton,
        'eggs_per_tray': eggsPerTray,
        'default_mortality_rate': defaultMortalityRate,
      };
}