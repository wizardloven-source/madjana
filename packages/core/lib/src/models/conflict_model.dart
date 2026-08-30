import 'package:core/core.dart';

/// نموذج تعارض المزامنة
class ConflictModel {
  final String id;
  final String tableName;
  final String recordId;
  final Map<String, dynamic> clientData;
  final Map<String, dynamic>? serverData;
  final String status; // 'pending', 'resolved', 'ignored'
  final DateTime createdAt;
  final String suggestedAction; // 'client_wins', 'server_wins', 'merge'

  ConflictModel({
    required this.id,
    required this.tableName,
    required this.recordId,
    required this.clientData,
    this.serverData,
    this.status = 'pending',
    required this.createdAt,
    required this.suggestedAction,
  });

  factory ConflictModel.fromJson(Map<String, dynamic> json) {
    return ConflictModel(
      id: json['id'],
      tableName: json['table_name'],
      recordId: json['record_id'],
      clientData: Map<String, dynamic>.from(json['client_data']),
      serverData: json['server_data'] != null 
          ? Map<String, dynamic>.from(json['server_data']) 
          : null,
      status: json['status'] ?? 'pending',
      createdAt: DateTime.parse(json['created_at']),
      suggestedAction: json['suggested_action'] ?? 'manual_review',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'table_name': tableName,
      'record_id': recordId,
      'client_data': clientData,
      'server_data': serverData,
      'status': status,
      'created_at': createdAt.toIso8601String(),
      'suggested_action': suggestedAction,
    };
  }
}
