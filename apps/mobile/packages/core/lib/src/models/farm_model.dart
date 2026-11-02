import 'dart:convert';

part 'farm_model.g.dart';

@JsonSerializable()
class FarmModel {
  final String id;
  final String farmName;
  final String farmCode;
  final String farmType;
  final DateTime createdAt;
  final DateTime updatedAt;
  final double feedBagWeightKg;
  final int traysPerBundle;
  final int eggsPerCarton;
  final int eggsPerTray;
  final double defaultMortalityRate;
  final int cartonLowThreshold;

  FarmModel({
    required this.id,
    required this.farmName,
    required this.farmCode,
    required this.farmType,
    required this.createdAt,
    required this.updatedAt,
    this.feedBagWeightKg = 50.0,
    this.traysPerBundle = 100,
    required this.eggsPerCarton,
    required this.eggsPerTray,
    required this.defaultMortalityRate,
    required this.cartonLowThreshold,
  });

  factory FarmModel.fromJson(Map<String, dynamic> json) => _$FarmModelFromJson(json);

  Map<String, dynamic> toJson() => _$FarmModelToJson(this);

  factory FarmModel.fromMap(Map<String, dynamic> map) {
    return FarmModel(
      id: map['id'] as String,
      farmName: map['farm_name'] as String,
      farmCode: map['farm_code'] as String,
      farmType: map['farm_type'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      feedBagWeightKg: map['feed_bag_weight_kg'] as double? ?? 50.0,
      traysPerBundle: map['trays_per_bundle'] as int? ?? 100,
      eggsPerCarton: map['eggs_per_carton'] as int,
      eggsPerTray: map['eggs_per_tray'] as int,
      defaultMortalityRate: (map['default_mortality_rate'] as num).toDouble(),
      cartonLowThreshold: map['carton_low_threshold'] as int,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'farm_name': farmName,
      'farm_code': farmCode,
      'farm_type': farmType,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'feed_bag_weight_kg': feedBagWeightKg,
      'trays_per_bundle': traysPerBundle,
      'eggs_per_carton': eggsPerCarton,
      'eggs_per_tray': eggsPerTray,
      'default_mortality_rate': defaultMortalityRate,
      'carton_low_threshold': cartonLowThreshold,
    };
  }

  FarmModel copyWith({
    String? id,
    String? farmName,
    String? farmCode,
    String? farmType,
    DateTime? createdAt,
    DateTime? updatedAt,
    double? feedBagWeightKg,
    int? traysPerBundle,
    int? eggsPerCarton,
    int? eggsPerTray,
    double? defaultMortalityRate,
    int? cartonLowThreshold,
  }) {
    return FarmModel(
      id: id ?? this.id,
      farmName: farmName ?? this.farmName,
      farmCode: farmCode ?? this.farmCode,
      farmType: farmType ?? this.farmType,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      feedBagWeightKg: feedBagWeightKg ?? this.feedBagWeightKg,
      traysPerBundle: traysPerBundle ?? this.traysPerBundle,
      eggsPerCarton: eggsPerCarton ?? this.eggsPerCarton,
      eggsPerTray: eggsPerTray ?? this.eggsPerTray,
      defaultMortalityRate: defaultMortalityRate ?? this.defaultMortalityRate,
      cartonLowThreshold: cartonLowThreshold ?? this.cartonLowThreshold,
    );
  }
}