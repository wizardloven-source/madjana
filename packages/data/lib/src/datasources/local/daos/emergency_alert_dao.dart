import '../local_database.dart';

/// سجل تنبيه طوارئ محلي قيد الإرسال
class EmergencyAlertRecord {
  final String id;
  final String farmId;
  final String alertType;
  final String? description;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime? sentAt;

  const EmergencyAlertRecord({
    required this.id,
    required this.farmId,
    required this.alertType,
    this.description,
    this.createdBy,
    required this.createdAt,
    this.sentAt,
  });

  bool get isPending => sentAt == null;

  Map<String, dynamic> toMap() => {
        'id': id,
        'farm_id': farmId,
        'alert_type': alertType,
        'description': description,
        'created_by': createdBy,
        'created_at': createdAt.toIso8601String(),
        if (sentAt != null) 'sent_at': sentAt!.toIso8601String(),
      };

  factory EmergencyAlertRecord.fromMap(Map<String, dynamic> map) {
    return EmergencyAlertRecord(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      alertType: map['alert_type'] as String,
      description: map['description'] as String?,
      createdBy: map['created_by'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      sentAt: map['sent_at'] != null
          ? DateTime.tryParse(map['sent_at'] as String)
          : null,
    );
  }
}

/// DAO لتنبيهات الطوارئ المحلية (offline-first)
/// - تُحفَظ محلياً فوراً عند الانقطاع
/// - تُعلَّم كمُرسَلة (sent_at) عند نجاح إيصالها للسحابة
class EmergencyAlertDao {
  static const _table = 'emergency_alerts';

  Future<String> add({
    required String farmId,
    required String alertType,
    String? description,
    String? createdBy,
  }) async {
    final db = await LocalDatabase.database;
    final record = EmergencyAlertRecord(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      farmId: farmId,
      alertType: alertType,
      description: description,
      createdBy: createdBy,
      createdAt: DateTime.now(),
    );
    await db.insert(_table, record.toMap());
    return record.id;
  }

  Future<List<EmergencyAlertRecord>> getPending() async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'sent_at IS NULL',
      orderBy: 'created_at ASC',
    );
    return maps.map(EmergencyAlertRecord.fromMap).toList();
  }

  Future<int> pendingCount() async {
    final db = await LocalDatabase.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_table WHERE sent_at IS NULL',
    );
    return (result.first['count'] as num?)?.toInt() ?? 0;
  }

  Future<void> markSent(String id) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {'sent_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    final db = await LocalDatabase.database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  /// تنظيف سجلات قديمة مُرسَلة (أكبر من 30 يوماً)
  Future<void> pruneSent({DateTime? olderThan}) async {
    final db = await LocalDatabase.database;
    final cutoff = (olderThan ??
            DateTime.now().subtract(const Duration(days: 30)))
        .toIso8601String();
    await db.delete(
      _table,
      where: 'sent_at IS NOT NULL AND sent_at < ?',
      whereArgs: [cutoff],
    );
  }
}