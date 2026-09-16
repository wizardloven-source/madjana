/// نماذج النسخ الاحتياطي

/// نوع النسخة الاحتياطية
enum BackupType {
  /// نسخة كاملة — جميع الجداول
  full,

  /// نسخة جزئية — طابور المزامنة فقط (للتشخيص)
  syncOnly,
}

/// حالة النسخة الاحتياطية
enum BackupStatus { success, failed, inProgress }

/// بيانات وصفية للنسخة الاحتياطية (تُخزَّن في ملف JSON بجانب الـ .db)
class BackupMetadata {
  final String id;
  final BackupType type;
  final BackupStatus status;
  final DateTime createdAt;
  final int fileSizeBytes;
  final String checksumSha256;
  final int dbVersion;
  final String? deviceName;
  final String? farmId;
  final String? errorMessage;

  const BackupMetadata({
    required this.id,
    required this.type,
    required this.status,
    required this.createdAt,
    required this.fileSizeBytes,
    required this.checksumSha256,
    required this.dbVersion,
    this.deviceName,
    this.farmId,
    this.errorMessage,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'status': status.name,
        'created_at': createdAt.toIso8601String(),
        'file_size_bytes': fileSizeBytes,
        'checksum_sha256': checksumSha256,
        'db_version': dbVersion,
        if (deviceName != null) 'device_name': deviceName,
        if (farmId != null) 'farm_id': farmId,
        if (errorMessage != null) 'error_message': errorMessage,
      };

  factory BackupMetadata.fromJson(Map<String, dynamic> json) =>
      BackupMetadata(
        id: json['id'] as String,
        type: BackupType.values.firstWhere(
          (e) => e.name == json['type'],
          orElse: () => BackupType.full,
        ),
        status: BackupStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => BackupStatus.failed,
        ),
        createdAt: DateTime.parse(json['created_at'] as String),
        fileSizeBytes: json['file_size_bytes'] as int,
        checksumSha256: json['checksum_sha256'] as String,
        dbVersion: json['db_version'] as int,
        deviceName: json['device_name'] as String?,
        farmId: json['farm_id'] as String?,
        errorMessage: json['error_message'] as String?,
      );

  BackupMetadata copyWith({
    BackupStatus? status,
    String? errorMessage,
  }) =>
      BackupMetadata(
        id: id,
        type: type,
        status: status ?? this.status,
        createdAt: createdAt,
        fileSizeBytes: fileSizeBytes,
        checksumSha256: checksumSha256,
        dbVersion: dbVersion,
        deviceName: deviceName,
        farmId: farmId,
        errorMessage: errorMessage ?? this.errorMessage,
      );
}

/// نتيجة إنشاء نسخة احتياطية
class BackupResult {
  final bool success;
  final BackupMetadata? metadata;
  final String? errorMessage;

  const BackupResult({required this.success, this.metadata, this.errorMessage});

  factory BackupResult.ok(BackupMetadata metadata) =>
      BackupResult(success: true, metadata: metadata);

  factory BackupResult.error(String message) =>
      BackupResult(success: false, errorMessage: message);
}

/// نتيجة استعادة نسخة احتياطية
class RestoreResult {
  final bool success;
  final int tablesAffected;
  final int recordsAffected;
  final String? errorMessage;

  const RestoreResult({
    required this.success,
    this.tablesAffected = 0,
    this.recordsAffected = 0,
    this.errorMessage,
  });

  factory RestoreResult.ok({required int recordsAffected}) =>
      RestoreResult(success: true, recordsAffected: recordsAffected);

  factory RestoreResult.error(String message) =>
      RestoreResult(success: false, errorMessage: message);
}
