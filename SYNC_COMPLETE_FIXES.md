# ✅ إصلاحات المزامنة المكتملة - Sync Protocol V2

## 📋 ملخص الإصلاحات المنفذة

### 1. قاعدة البيانات (Supabase) ✅
**الملف**: `/workspace/supabase/migrations/20250101000000_fix_sync_protocol_v2.sql`

#### التغييرات:
- ✅ استبدال `sync_queue` بـ `sync_changes` مع `server_version`
- ✅ إنشاء تسلسل `global_sync_version` لتوليد أرقام إصدارات فريدة
- ✅ دالة RPC آمنة `sync_records_batch(jsonb, uuid)`:
  - تتحقق من JWT عبر `auth.uid()`
  - ترفض `user_id` مختلف عن JWT
  - تتحقق من ملكية المزرعة (Farm Ownership)
  - تدعم INSERT, UPDATE, DELETE
  - تطبق Last Write Wins بناءً على `updated_at`
  - تسجل كل تغيير في `sync_changes`
- ✅ إضافة `deleted_at` لـ 6 جداول للـ Soft Delete

### 2. Edge Function ✅
**الملف**: `/workspace/supabase/functions/sync_records/index.ts`

#### التحسينات الأمنية:
- ✅ التحقق من JWT Token قبل المعالجة
- ✅ عدم الثقة في `body.user_id` المرسل من العميل
- ✅ استخدام `user.id` من JWT فقط
- ✅ تطبيع السجلات والتحقق من صحتها
- ✅ حد أقصى 100 سجل لكل دفعة

### 3. Flutter SyncRepositoryImpl ✅
**الملف**: `/workspace/packages/data/lib/src/repositories/sync_repository_impl.dart`

#### التغييرات الجذرية:

##### أ. إعادة كتابة `uploadBatch()`:
```dart
// القديم: رفع منفصل لكل جدول عبر datasources
// الجديد: استدعاء موحد لـ Edge Function

final payload = records.map((record) {
  return {
    'table': record.tableName,
    'action': record.operation, // INSERT/UPDATE/DELETE
    'data': record.payload,
  };
}).toList();

final response = await client.functions.invoke('sync_records', body: {
  'records': payload,
});
```

##### ب. إصلاح `markAsSynced()`:
```dart
// القديم (خاطئ): markAsSynced(String id) - يحدث كل الجداول
// الجديد (صحيح): markAsSyncedById(String tableName, String recordId)

Future<void> markAsSyncedById(String tableName, String recordId) async {
  switch (tableName) {
    case 'egg_production': await _eggDao.updateSyncStatus(...); break;
    case 'payments': await _paymentDao.updateSyncStatus(...); break;
    // ... باقي الجداول
  }
}
```

##### ج. Incremental Pull:
```dart
// جلب السجلات المحدثة فقط منذ آخر مزامنة
final lastSync = _lastSyncTimes[table] ?? DateTime.utc(2000);
final rows = await _remoteEgg.client
    .from(table)
    .select()
    .eq('farm_id', farmId)
    .gte('updated_at', lastSync.toIso8601String());
```

##### د. دعم Soft Delete:
```dart
if (hasDeletedAt && row['deleted_at'] != null) {
  await db.delete(table, where: 'id = ?', whereArgs: [id]);
  continue;
}
```

##### هـ. تسجيل الأخطاء:
```dart
// القديم: catch (_) {} - يبتلع الأخطاء
// الجديد: catch (e, stackTrace) { await logError('$e\n$stackTrace'); }
```

### 4. DAOs المضافة ✅

#### PaymentDao:
- ✅ `getPendingRecords({int limit})`
- ✅ `updateSyncStatus(String id, SyncStatus status)`
- ✅ `countPending()`

#### ExpenseDao:
- ✅ `getPendingRecords({int limit})`
- ✅ `updateSyncStatus(String id, SyncStatus status)`
- ✅ `countPending()`

---

## 🏗️ المعمارية الجديدة

```
┌──────────────────┐
│   Flutter Local  │
│     SQLite       │
└────────┬─────────┘
         │
         ▼
  Local Sync Queue
         │
         ▼
┌──────────────────┐
│  Edge Function   │ ← JWT Verification
│  sync_records    │ ← Farm Validation
└────────┬─────────┘ ← Role-Based Access
         │
         ▼
  sync_records_batch()
         │
         ├────────────┐
         ▼            ▼
   Main Tables   sync_changes
   (INSERT/       (server_version
    UPDATE/        operation
    DELETE)        deleted_at)
```

---

## 📦 خطوات النشر

### 1. تطبيق Migration على Supabase

```bash
# التأكد من وجود Supabase CLI
npm install -g supabase

# تسجيل الدخول
supabase login

# ربط المشروع
supabase link --project-ref iefwbcwhpyajhohpxwmj

# تطبيق Migration
supabase db push
```

### 2. نشر Edge Function

```bash
# نشر الدالة
supabase functions deploy sync_records

# التحقق من النشر
supabase functions list
```

### 3. اختبار المزامنة

```bash
# إنشاء سجل جديد في الموبايل
# مراقبة الطابور المحلي
SELECT * FROM sync_queue WHERE status = 'pending';

# تشغيل المزامنة يدوياً
await syncEngine.syncNow();

# التحقق من sync_changes
SELECT * FROM sync_changes ORDER BY server_version DESC LIMIT 10;

# التحقق من السجلات الناجحة
SELECT * FROM egg_production WHERE sync_status = 'synced';
```

---

## 🔒 التحسينات الأمنية

| المشكلة القديمة | الحل الجديد |
|----------------|-------------|
| ثقة عمياء في `body.user_id` | استخدام `auth.uid()` فقط |
| لا تحقق من Farm Ownership | تحقق صارم من `farm_id` |
| وصول عام للدوال | `SECURITY DEFINER` + `GRANT EXECUTE` |
| لا حد للدفعة | حد أقصى 100 سجل |
| لا تحقق من الأدوار | RBAC للجداول الحساسة |

---

## 📊 مقارنة البروتوكولات

### البروتوكول القديم ❌

```
Flutter → Table مباشرة → RLS Issues
         ↓
      No Sync Log
         ↓
   No Versioning
```

### البروتوكول الجديد ✅

```
Flutter → Edge Function → JWT Check
         ↓
    sync_records_batch
         ↓
    Farm Validation
         ↓
    Last Write Wins
         ↓
    UPSERT + Log
         ↓
    sync_changes (versioned)
```

---

## ⚠️ ملاحظات مهمة

### 1. الجداول التي تحتاج `updated_at` و `deleted_at`:
- ✅ feed_consumption
- ✅ feed_received
- ✅ egg_dispatch
- ✅ payments
- ✅ medications
- ✅ expenses

### 2. الجداول المحمية بـ Manager Only:
- payments
- expenses
- opening_balances
- inventory_items
- inventory_transactions
- app_notifications

### 3. Limit الـ Pull:
- تم تقسيم الـ 50 سجل على 7 جداول (~7 لكل جدول)
- يمكن تعديلها حسب الحاجة

---

## 🧪 الاختبارات المطلوبة

### 1. اختبار الرفع الموحد:
```dart
test('uploadBatch uses Edge Function', () async {
  final records = [
    SyncRecord(
      tableName: 'egg_production',
      recordId: 'uuid',
      payload: {...},
      operation: 'INSERT',
    ),
  ];
  
  final result = await repo.uploadBatch(records);
  expect(result.successIds, isNotEmpty);
});
```

### 2. اختبار Incremental Pull:
```dart
test('pullRemoteRecords fetches only new changes', () async {
  final pulled = await repo.pullRemoteRecords(farmId);
  // يجب أن يجلب فقط السجلات المحدثة منذ آخر مزامنة
});
```

### 3. اختبار Soft Delete:
```dart
test('deleted records are removed locally', () async {
  // حذف سجل في Supabase
  // تشغيل Pull
  // التحقق من حذفه محلياً
});
```

### 4. اختبار التعارضات:
```dart
test('conflict resolution uses Last Write Wins', () async {
  // تعديل نفس السجل في جهازين
  // التحقق من فوز الأحدث updated_at
});
```

---

## 📈 المقاييس المتوقعة

| المقياس | قبل | بعد |
|---------|-----|-----|
| وقت الرفع (100 سجل) | ~5 ثواني | ~1 ثانية |
| فقدان البيانات | محتمل | معدوم |
| التعارضات غير المحلولة | شائعة | نادرة |
| استهلاك البيانات | عالي | منخفض (incremental) |
| الأمان | ضعيف | قوي (JWT + RBAC) |

---

## 🚀 الخطوات التالية

1. **تطبيق Migration** على Supabase
2. **نشر Edge Function**
3. **اختبار شامل** للمزامنة
4. **مراقبة الأخطاء** في `sync_queue` و `sync_changes`
5. **تحسين الأداء** إذا لزم الأمر (pagination، caching)

---

## 📞 الدعم

للأسئلة أو المشاكل:
1. راجع سجلات Edge Function في Supabase Dashboard
2. تحقق من جدول `sync_changes` لفهم تدفق المزامنة
3. استخدم `logError()` لتتبع الأخطاء في Flutter
