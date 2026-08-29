/// نموذج المدجنة
class FarmModel {
  final String id;
  final String name;
  final String? location;
  final String? ownerId;
  final DateTime? createdAt;

  const FarmModel({
    required this.id,
    required this.name,
    this.location,
    this.ownerId,
    this.createdAt,
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
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'location': location,
        'owner_id': ownerId,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      };
}