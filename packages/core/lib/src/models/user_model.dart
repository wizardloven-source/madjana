import '../constants/enums.dart';

/// نموذج المستخدم
class UserModel {
  final String uid;
  final String name;
  final String phone;
  final UserRole role;
  final String? farmId;
  final List<String> farmIds;
  final bool isActive;
  final DateTime createdAt;

  const UserModel({
    required this.uid,
    required this.name,
    required this.phone,
    required this.role,
    this.farmId,
    this.farmIds = const [],
    this.isActive = true,
    required this.createdAt,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      uid: json['uid'] as String,
      name: json['name'] as String,
      phone: json['phone'] as String,
      role: UserRole.values.firstWhere(
        (e) => e.name == json['role'],
        orElse: () => UserRole.worker,
      ),
      farmId: json['farm_id'] as String?,
      farmIds: _parseFarmIds(json),
      isActive: json['is_active'] as bool? ?? true,
      createdAt: json['created_at'] == null
          ? DateTime.now()
          : DateTime.parse(json['created_at'].toString()),
    );
  }

  static List<String> _parseFarmIds(Map<String, dynamic> json) {
    final ids = json['farm_ids'];
    if (ids is List) {
      return ids.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    }
    final single = json['farm_id'] as String?;
    return (single == null || single.isEmpty) ? const [] : [single];
  }

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'name': name,
        'phone': phone,
        'role': role.name,
        'farm_id': farmId,
        'farm_ids': farmIds,
        'is_active': isActive,
        'created_at': createdAt.toIso8601String(),
      };

  UserModel copyWith({
    String? name,
    String? phone,
    UserRole? role,
    String? farmId,
    List<String>? farmIds,
    bool? isActive,
  }) {
    return UserModel(
      uid: uid,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      farmId: farmId ?? this.farmId,
      farmIds: farmIds ?? this.farmIds,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
    );
  }
}