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
    // ═══ C8 FIX: أمان كامل ضد القيم null/الأنواع الخاطئة ═══
    final clientRaw = json['client_data'];
    final serverRaw = json['server_data'];
    return ConflictModel(
      id: json['id']?.toString() ?? '',
      tableName: json['table_name']?.toString() ?? '',
      recordId: json['record_id']?.toString() ?? '',
      clientData: clientRaw is Map
          ? Map<String, dynamic>.from(clientRaw)
          : <String, dynamic>{},
      serverData: serverRaw is Map
          ? Map<String, dynamic>.from(serverRaw)
          : null,
      status: json['status']?.toString() ?? 'pending',
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      suggestedAction: json['suggested_action']?.toString() ?? 'manual_review',
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
