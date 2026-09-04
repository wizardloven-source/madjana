/// إدخال صحة مزامنة لمزرعة — يُغذّي شاشة SYNC CENTER (لـ system_admin).
class SyncHealthEntry {
  final String farmId;
  final String farmName;
  final int deviceCount;
  final int onlineDevices;
  final int offlineDevices;
  final int pendingConflicts;
  final DateTime? lastSync;
  final int latestVersion;

  const SyncHealthEntry({
    required this.farmId,
    required this.farmName,
    required this.deviceCount,
    required this.onlineDevices,
    required this.offlineDevices,
    required this.pendingConflicts,
    this.lastSync,
    required this.latestVersion,
  });

  factory SyncHealthEntry.fromJson(Map<String, dynamic> json) {
    return SyncHealthEntry(
      farmId: json['farm_id'] as String,
      farmName: json['farm_name'] as String,
      deviceCount: (json['device_count'] as num?)?.toInt() ?? 0,
      onlineDevices: (json['online_devices'] as num?)?.toInt() ?? 0,
      offlineDevices: (json['offline_devices'] as num?)?.toInt() ?? 0,
      pendingConflicts: (json['pending_conflicts'] as num?)?.toInt() ?? 0,
      lastSync: json['last_sync'] != null
          ? DateTime.tryParse(json['last_sync'] as String)
          : null,
      latestVersion: (json['latest_version'] as num?)?.toInt() ?? 0,
    );
  }
}
