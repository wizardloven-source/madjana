/// عقد المزامنة بين العميل والخادم (M9 — docs/SYNC.md).
///
/// ⚠ هذا الرقم **مختلف المقياس** عن `_dbVersion` في
/// `packages/data/lib/src/datasources/local/local_database.dart`:
///
/// * [kSyncContractVersion] — **عصر عقد المزامنة** (الخادم ↔ العميل):
///   ينطلق من 1، ويُرفع يدوياً فقط عند تغيير يكسر المزامنة، بالتوافق مع صف
///   `app_schema_version` على الخادم. هذا هو الرقم الوحيد الذي تُقارنه بوابة
///   الإقلاع بـ `current_schema_version()`.
/// * `_dbVersion` — **عدّاد ترحيلات SQLite المحلية** (محلي بحت): يرتفع مع كل
///   تغيير في قاعدة الجهاز (فهارس، `sync_queue`، OCC، علامة مائية...) وليس
///   له علاقة بعقد الخادم. لا يُقارن بالخادم ولا يُرسل إليه.
library;

/// عصر عقد المزامنة الذي بُني له هذا الإصدار من التطبيق.
///
/// يُرفع بالتزامن مع `app_schema_version.version` على الخادم عندما يتغير عقد
/// المزامنة (تغيير يكسر توافق العميل/الخادم). انظر docs/SYNC.md.
const int kSyncContractVersion = 1;

/// نتيجة مقارنة عقد العميل ([kSyncContractVersion]) بإصدار مخطط الخادم.
enum SyncContractState {
  /// عقد العميل == إصدار الخادم → المزامنة مسموحة.
  match,

  /// الخادم أحدث من العقد (`server > contract`) → **حظر**: حدّث التطبيق.
  serverAhead,

  /// عقد العميل أحدث من الخادم (`contract > server`) → **تحذير فقط**: التطبيق
  /// مبني لعقدٍ لم يُنشَر على الخادم بعد. لا حظر (يُصحّح بنشر ترحيلات الخادم).
  clientAhead,

  /// تعذّر قراءة إصدار الخادم (offline / RPC فشل) → لا حظر (Offline-first).
  unknown,
}

/// يقارن عقد العميل بإصدار الخادم ويعيد الحالة المقابلة.
///
/// [serverVersion] == null يعني تعذّر قراءة إصدار الخادم (offline).
SyncContractState evaluateSyncContract({
  required int contractVersion,
  required int? serverVersion,
}) {
  if (serverVersion == null) return SyncContractState.unknown;
  if (serverVersion == contractVersion) return SyncContractState.match;
  if (serverVersion > contractVersion) return SyncContractState.serverAhead;
  return SyncContractState.clientAhead;
}
