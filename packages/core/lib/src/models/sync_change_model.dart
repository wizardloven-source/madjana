import 'dart:convert';
import '../constants/enums.dart';

enum SyncOperation { insert, update, delete }

class SyncChangeModel {
  final String? operationId; // معرّف فريد لكل عملية (لا يشبه recordId)
  final int? id; // BigInt ID from DB
  final String farmId;
  final String tableName;
  final String recordId;
  final SyncOperation operation;
  final DateTime changedAt;
  final String? userId;
  final Map<String, dynamic>? payload;
  final SyncStatus status;
  final int? serverVersion;
  final String? errorMessage;
  final int attempts;

  SyncChangeModel({
    this.operationId,
    this.id,
    required this.farmId,
    required this.tableName,
    required this.recordId,
    required this.operation,
    required this.changedAt,
    this.userId,
    this.payload,
    this.status = SyncStatus.pending,
    this.serverVersion,
    this.errorMessage,
    this.attempts = 0,
  });

  /// إنشاء نموذج من خريطة قاعدة البيانات (SQLite/Supabase)
  factory SyncChangeModel.fromMap(Map<String, dynamic> map) {
    return SyncChangeModel(
      operationId: map['operation_id'] as String?,
      id: map['id'] is int ? map['id'] : int.tryParse(map['id']?.toString() ?? ''),
      farmId: map['farm_id'] as String,
      tableName: map['table_name'] as String,
      recordId: map['record_id'] as String,
      operation: SyncOperation.values.firstWhere(
        (e) => e.name == map['operation'],
        orElse: () => SyncOperation.insert,
      ),
      changedAt: map['changed_at'] is DateTime
          ? map['changed_at']
          : DateTime.parse(map['changed_at'] as String),
      userId: map['user_id'] as String?,
      payload: map['payload'] != null
          ? (map['payload'] is String
              ? jsonDecode(map['payload'])
              : map['payload'])
          : null,
      status: SyncStatus.values.firstWhere(
        (e) => e.name == (map['status'] ?? 'pending'),
        orElse: () => SyncStatus.pending,
      ),
      serverVersion: map['server_version'] as int?,
      errorMessage: map['error_message'] as String?,
      attempts: (map['attempts'] as num?)?.toInt() ?? 0,
    );
  }

  /// تحويل النموذج إلى خريطة للحفظ في قاعدة البيانات
  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      if (operationId != null) 'operation_id': operationId,
      'farm_id': farmId,
      'table_name': tableName,
      'record_id': recordId,
      'operation': operation.name,
      'changed_at': changedAt.toIso8601String(),
      if (userId != null) 'user_id': userId,
      if (payload != null) 'payload': jsonEncode(payload),
      'status': status.name,
      if (serverVersion != null) 'server_version': serverVersion,
      if (errorMessage != null) 'error_message': errorMessage,
      'attempts': attempts,
    };
  }

  /// إنشاء نسخة محدثة من النموذج
  /// ملاحظة: استخدم علم (sentinel) للسماح بإفراغ الحقول nullable مثل payload.
  SyncChangeModel copyWith({
    String? operationId,
    int? id,
    String? farmId,
    String? tableName,
    String? recordId,
    SyncOperation? operation,
    DateTime? changedAt,
    String? userId,
    Map<String, dynamic>? payload,
    SyncStatus? status,
    int? serverVersion,
    String? errorMessage,
    int? attempts,
    bool clearPayload = false,
    bool clearError = false,
    bool clearServerVersion = false,
  }) {
    return SyncChangeModel(
      operationId: operationId ?? this.operationId,
      id: id ?? this.id,
      farmId: farmId ?? this.farmId,
      tableName: tableName ?? this.tableName,
      recordId: recordId ?? this.recordId,
      operation: operation ?? this.operation,
      changedAt: changedAt ?? this.changedAt,
      userId: userId ?? this.userId,
      payload: clearPayload ? null : (payload ?? this.payload),
      status: status ?? this.status,
      serverVersion: clearServerVersion ? null : (serverVersion ?? this.serverVersion),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      attempts: attempts ?? this.attempts,
    );
  }
}
