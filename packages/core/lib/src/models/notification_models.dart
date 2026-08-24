/// نموذج إشعار من المدير للعامل
class AppNotificationModel {
  final String id;
  final String farmId;
  final String? flockId;
  final String title;
  final String? body;

  /// info | warning | danger
  final String level;
  final bool isPersistent;
  final bool isActive;
  final DateTime? createdAt;

  const AppNotificationModel({
    required this.id,
    required this.farmId,
    this.flockId,
    required this.title,
    this.body,
    this.level = 'info',
    this.isPersistent = false,
    this.isActive = true,
    this.createdAt,
  });

  factory AppNotificationModel.fromJson(Map<String, dynamic> json) {
    return AppNotificationModel(
      id: json['id'] as String,
      farmId: json['farm_id'] as String,
      flockId: json['flock_id'] as String?,
      title: json['title'] as String,
      body: json['body'] as String?,
      level: json['level'] as String? ?? 'info',
      isPersistent: json['is_persistent'] as bool? ?? false,
      isActive: json['is_active'] as bool? ?? true,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'farm_id': farmId,
        if (flockId != null) 'flock_id': flockId,
        'title': title,
        if (body != null) 'body': body,
        'level': level,
        'is_persistent': isPersistent,
        'is_active': isActive,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      };
}

/// تذكير خاص بالعامل (محلي فقط — لا يُزامَن)
class ReminderModel {
  final String id;
  final String title;
  final String? body;
  final DateTime createdAt;

  const ReminderModel({
    required this.id,
    required this.title,
    this.body,
    required this.createdAt,
  });

  factory ReminderModel.fromMap(Map<String, dynamic> map) {
    return ReminderModel(
      id: map['id'] as String,
      title: map['title'] as String,
      body: map['body'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'body': body,
        'created_at': createdAt.toIso8601String(),
      };
}
