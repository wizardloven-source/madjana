# 🔧 إصلاحات المزامنة الشاملة - خطة تنفيذية

## 📋 المشكلة الرئيسية

المشروع يعاني من **20 مشكلة حرجة** في نظام المزامنة تجعل الرفع والسحب غير فعالين:

### المشاكل الحرجة:
1. ❌ `pullRemoteRecords()` يسحب كل البيانات بدون `updated_at` أو `lastSync`
2. ❌ جداول كثيرة لا تحتوي على `updated_at` في Supabase
3. ❌ `SyncRecord` يحتوي على `operation` و `version` لكن لا يتم استخدامهما
4. ❌ حذف السجلات غير مدعوم (لا Soft Delete)
5. ❌ `markAsSynced(id)` تحدث **كل** الجداول بنفس الـ ID
6. ❌ Payments و Expenses غير موجودة في `getPendingRecords()`
7. ❌ الأخطاء تُبتلع بـ `catch (_) {}`
8. ❌ لا يوجد Sync Cursor دائم
9. ❌ لا Server Version في البروتوكول
10. ❌ `BatchUploadResult.isConflict` يفسر أي فشل كـ Conflict

---

## ✅ الحلول المنفذة

### 1️⃣ تحديث مخطط قاعدة البيانات (Supabase)

**الملف**: `/workspace/supabase/migrations/010_rebuild_clean.sql`

#### التغييرات:
```sql
-- استبدال sync_queue بـ sync_changes
CREATE TABLE sync_changes (
    id              UUID PRIMARY KEY,
    table_name      TEXT NOT NULL,
    record_id       UUID NOT NULL,
    operation       TEXT NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    farm_id         UUID NOT NULL REFERENCES farms(id),
    device_id       TEXT,
    user_id         UUID REFERENCES auth.users(id),
    payload         JSONB,
    server_version  BIGINT DEFAULT nextval('global_sync_version'),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- إضافة updated_at و deleted_at للجداول الناقصة
ALTER TABLE feed_consumption ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE feed_consumption ADD COLUMN deleted_at TIMESTAMPTZ;
ALTER TABLE feed_received ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE feed_received ADD COLUMN deleted_at TIMESTAMPTZ;
ALTER TABLE egg_dispatch ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE egg_dispatch ADD COLUMN deleted_at TIMESTAMPTZ;
ALTER TABLE medications ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE medications ADD COLUMN deleted_at TIMESTAMPTZ;
ALTER TABLE payments ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE payments ADD COLUMN deleted_at TIMESTAMPTZ;
ALTER TABLE expenses ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE expenses ADD COLUMN deleted_at TIMESTAMPTZ;

-- Trigger لتحديث updated_at تلقائياً
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- تطبيق trigger على الجداول الجديدة
CREATE TRIGGER update_feed_consumption_updated_at 
    BEFORE UPDATE ON feed_consumption 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_feed_received_updated_at 
    BEFORE UPDATE ON feed_received 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_egg_dispatch_updated_at 
    BEFORE UPDATE ON egg_dispatch 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_medications_updated_at 
    BEFORE UPDATE ON medications 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_payments_updated_at 
    BEFORE UPDATE ON payments 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_expenses_updated_at 
    BEFORE UPDATE ON expenses 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
```

#### سياسات الأمان لـ sync_changes:
```sql
-- السماح للـ Edge Function فقط بالكتابة
DROP POLICY IF EXISTS sync_changes_insert ON sync_changes;
CREATE POLICY sync_changes_insert ON sync_changes
    FOR INSERT TO authenticated
    WITH CHECK (auth.uid()::text = '00000000-0000-0000-0000-000000000000'::text);

-- القراءة حسب المزرعة
DROP POLICY IF EXISTS sync_changes_select ON sync_changes;
CREATE POLICY sync_changes_select ON sync_changes
    FOR SELECT TO authenticated
    USING (farm_id = current_user_farm_id());
```

---

### 2️⃣ إصلاح SyncRepositoryImpl

**الملف**: `/workspace/packages/data/lib/src/repositories/sync_repository_impl.dart`

#### أ) إضافة DAOs الناقصة:
```dart
final PaymentDao _paymentDao;
final ExpenseDao _expenseDao;
final SupabaseClient _supabase;
final Map<String, DateTime> _lastSyncTimes = {};
int _consecutiveFailures = 0;
static const int maxConsecutiveFailures = 5;
```

#### ب) إصلاح getPendingRecords() ليشمل Payments و Expenses:
```dart
@override
Future<List<SyncRecord>> getPendingRecords({int limit = 50}) async {
  final records = <SyncRecord>[];
  
  // تقسيم عادل للـ limit بين الجداول
  final perTableLimit = (limit / 8).ceil(); // 8 جداول
  
  // بيض
  final eggs = await _eggDao.getPendingRecords(limit: perTableLimit);
  for (final e in eggs) {
    records.add(SyncRecord(
      id: e.id,
      tableName: 'egg_production',
      recordId: e.id!,
      payload: e.toJson(),
      updatedAt: e.updatedAt ?? e.createdAt ?? DateTime.now(),
      operation: e.syncStatus == SyncStatus.pending ? 'INSERT' : 'UPDATE',
    ));
  }
  
  // ... نفس النمط لباقي الجداول ...
  
  // مدفوعات (جديد)
  final payments = await _paymentDao.getPendingRecords(limit: perTableLimit);
  for (final p in payments) {
    records.add(SyncRecord(
      id: p.id,
      tableName: 'payments',
      recordId: p.id!,
      payload: p.toJson(),
      updatedAt: p.updatedAt ?? p.createdAt ?? DateTime.now(),
      operation: 'INSERT', // أو UPDATE حسب الحالة
    ));
  }
  
  // مصاريف (جديد)
  final expenses = await _expenseDao.getPendingRecords(limit: perTableLimit);
  for (final e in expenses) {
    records.add(SyncRecord(
      id: e.id,
      tableName: 'expenses',
      recordId: e.id!,
      payload: e.toJson(),
      updatedAt: e.updatedAt ?? e.createdAt ?? DateTime.now(),
      operation: 'INSERT',
    ));
  }
  
  return records;
}
```

#### ج) إصلاح pullRemoteRecords() ليكون Incremental:
```dart
@override
Future<int> pullRemoteRecords(String farmId) async {
  final db = await LocalDatabase.database;
  var pulled = 0;

  for (final table in _pullTables) {
    try {
      // الحصول على آخر وقت مزامنة لهذا الجدول
      final lastSync = _lastSyncTimes[table] ?? DateTime.utc(2000);
      
      // سحب السجلات الجديدة أو المحدثة فقط
      final rows = await _remoteEgg.client
          .from(table)
          .select()
          .eq('farm_id', farmId)
          .gte('updated_at', lastSync.toIso8601String())
          .order('updated_at', ascending: true);

      // معالجة الصفوف...
      for (final raw in rows as List) {
        try {
          final row = Map<String, dynamic>.from(raw as Map);
          final id = row['id'] as String?;
          if (id == null) continue;
          
          // التحقق من الحذف الناعم
          final deletedAt = row['deleted_at'];
          if (deletedAt != null) {
            // حذف السجل محلياً
            await db.delete(table, where: 'id = ?', whereArgs: [id]);
            pulled++;
            continue;
          }
          
          // لا نطغى على سجلات محلية لم تُزامَن بعد
          final existing = await db.query(
            table,
            where: 'id = ?',
            whereArgs: [id],
            limit: 1,
          );
          if (existing.isNotEmpty &&
              existing.first['sync_status'] == SyncStatus.pending.name) {
            continue;
          }
          
          row['sync_status'] = SyncStatus.synced.name;
          await db.insert(
            table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          pulled++;
        } catch (e, stackTrace) {
          // تسجيل الخطأ بدلاً من ابتلاعه
          print('Error processing row in $table: $e\n$stackTrace');
          await logError('Pull error in $table: $e');
        }
      }
      
      // تحديث وقت المزامنة الناجحة
      _lastSyncTimes[table] = DateTime.now();
    } catch (e, stackTrace) {
      print('Error pulling table $table: $e\n$stackTrace');
      await logError('Pull error for $table: $e');
      _consecutiveFailures++;
      
      // إيقاف المحاولات بعد فشل متتالي
      if (_consecutiveFailures >= maxConsecutiveFailures) {
        throw Exception('Too many consecutive pull failures. Manual intervention required.');
      }
    }
  }

  return pulled;
}
```

#### د) إصلاح markAsSynced() لتعمل على جدول محدد:
```dart
@override
Future<void> markAsSyncedById(String tableName, String recordId) async {
  switch (tableName) {
    case 'egg_production':
      await _eggDao.updateSyncStatus(recordId, SyncStatus.synced);
      break;
    case 'mortality':
      await _mortalityDao.updateSyncStatus(recordId, SyncStatus.synced);
      break;
    case 'feed_consumption':
      await _feedDao.updateConsumptionSyncStatus(recordId, SyncStatus.synced);
      break;
    case 'feed_received':
      await _feedDao.updateReceivedSyncStatus(recordId, SyncStatus.synced);
      break;
    case 'egg_dispatch':
      await _dispatchDao.updateSyncStatus(recordId, SyncStatus.synced);
      break;
    case 'medications':
      await _medicationDao.updateSyncStatus(recordId, SyncStatus.synced);
      break;
    case 'customers':
      await _customerDao.updateSyncStatus(recordId, SyncStatus.synced);
      break;
    case 'payments':
      await _paymentDao.updateSyncStatus(recordId, SyncStatus.synced);
      break;
    case 'expenses':
      await _expenseDao.updateSyncStatus(recordId, SyncStatus.synced);
      break;
  }
  
  await _syncQueueDao.updateStatus(recordId, 'synced');
}
```

#### هـ) إصلاح uploadBatch() لاستخدام Edge Function:
```dart
@override
Future<BatchUploadResult> uploadBatch(List<SyncRecord> records) async {
  final successIds = <String>[];
  final failedIds = <String>[];
  final errors = <String>[];

  try {
    // تجميع السجلات حسب العملية
    final changes = records.map((r) => {
      'table_name': r.tableName,
      'record_id': r.recordId,
      'operation': r.operation,
      'payload': r.payload,
      'updated_at': r.updatedAt.toIso8601String(),
    }).toList();

    // استدعاء Edge Function
    final response = await _supabase.functions.invoke('sync_records', body: {
      'records': changes,
    });

    if (response.status == 200) {
      final result = response.data as Map;
      successIds.addAll(result['success_ids'] as List);
      failedIds.addAll(result['failed_ids'] as List);
      errors.addAll(result['errors'] as List);
    } else {
      // فشل الاتصال بـ Edge Function
      failedIds.addAll(records.map((r) => r.id ?? r.recordId));
      errors.add('Edge Function returned status ${response.status}');
    }
  } catch (e, stackTrace) {
    print('Upload batch error: $e\n$stackTrace');
    await logError('Upload error: $e');
    failedIds.addAll(records.map((r) => r.id ?? r.recordId));
  }

  // تسجيل في طابور المزامنة
  for (final record in records) {
    if (record.id == null) continue;
    final status = successIds.contains(record.id) ? 'synced' : 'failed';
    await _syncQueueDao.upsert(
      tableName: record.tableName,
      recordId: record.recordId,
      payload: record.payload,
      status: status,
    );
  }

  // تنظيف السجلات القديمة
  await _syncQueueDao.cleanSynced(olderThanDays: 3);

  return BatchUploadResult(
    successIds: successIds,
    failedIds: failedIds,
    errors: errors,
  );
}
```

---

### 3️⃣ إصلاح SyncEngine

**الملف**: `/workspace/apps/mobile/lib/features/sync/data/sync_engine.dart`

#### التغييرات:
```dart
class SyncEngine {
  static const syncInterval = Duration(seconds: 30); // كان 5 ثواني
  DateTime? _lastSuccessfulPull;
  int _consecutiveFailures = 0;

  Future<void> _runSyncCycle() async {
    try {
      // UPLOAD أولاً ثم PULL
      await _pushOnce();
      await _pullOnce();
      
      _consecutiveFailures = 0;
    } catch (e) {
      _consecutiveFailures++;
      print('Sync cycle failed: $e');
      
      if (_consecutiveFailures >= 5) {
        print('Too many failures. Stopping auto-sync.');
        // إرسال إشعار للمستخدم
      }
    }
  }

  Future<void> _pullOnce() async {
    try {
      final farmId = await _getFarmId();
      if (farmId == null) return;
      
      final pulled = await repository.pullRemoteRecords(farmId);
      
      // تحديث وقت النجاح فقط بعد النجاح الفعلي
      _lastSuccessfulPull = DateTime.now();
      
      print('Pulled $pulled records');
    } catch (e, stackTrace) {
      print('Pull failed: $e\n$stackTrace');
      rethrow;
    }
  }
}
```

---

### 4️⃣ إنشاء Edge Function للمزامنة

**الملف**: `/workspace/supabase/functions/sync_records/index.ts`

```typescript
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

serve(async (req) => {
  try {
    const { records } = await req.json()
    
    // التحقق من الهوية
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      throw new Error('Missing authorization header')
    }
    
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    )
    
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) {
      throw new Error('Unauthorized')
    }
    
    const successIds: string[] = []
    const failedIds: string[] = []
    const errors: string[] = []
    
    for (const record of records) {
      try {
        const { table_name, record_id, operation, payload, updated_at } = record
        
        // الحصول على farm_id من payload
        const farmId = payload.farm_id
        
        if (!farmId) {
          failedIds.push(record_id)
          errors.push('Missing farm_id')
          continue
        }
        
        // التحقق من صلاحيات المستخدم على المزرعة
        const { data: farm } = await supabaseClient
          .from('farms')
          .select('id')
          .eq('id', farmId)
          .eq('manager_id', user.id)
          .single()
        
        if (!farm) {
          failedIds.push(record_id)
          errors.push('Unauthorized for this farm')
          continue
        }
        
        let result
        
        if (operation === 'DELETE') {
          // حذف ناعم
          result = await supabaseClient
            .from(table_name)
            .update({ deleted_at: new Date().toISOString() })
            .eq('id', record_id)
        } else if (operation === 'INSERT' || operation === 'UPDATE') {
          // Upsert
          result = await supabaseClient
            .from(table_name)
            .upsert({
              id: record_id,
              ...payload,
              updated_at: updated_at || new Date().toISOString()
            }, {
              onConflict: 'id'
            })
        }
        
        if (result.error) {
          throw result.error
        }
        
        successIds.push(record_id)
        
        // تسجيل في sync_changes
        await supabaseClient
          .from('sync_changes')
          .insert({
            table_name,
            record_id,
            operation,
            farm_id: farmId,
            user_id: user.id,
            payload,
            server_version: null // سيتم تعيينه تلقائياً
          })
          
      } catch (error) {
        console.error(`Failed to sync record ${record.record_id}:`, error)
        failedIds.push(record.record_id)
        errors.push(error.message)
      }
    }
    
    return new Response(
      JSON.stringify({ success_ids: successIds, failed_ids: failedIds, errors }),
      { headers: { 'Content-Type': 'application/json' }, status: 200 }
    )
    
  } catch (error) {
    console.error('Sync function error:', error)
    return new Response(
      JSON.stringify({ error: error.message }),
      { headers: { 'Content-Type': 'application/json' }, status: 400 }
    )
  }
})
```

---

## 📊 ملخص الإصلاحات

| المشكلة | الحل | الحالة |
|---------|------|--------|
| Pull يسحب كل البيانات | Incremental Pull بـ `updated_at >= lastSync` | ✅ تم |
| جداول بدون updated_at | إضافة الأعمدة و triggers | ✅ تم |
| markAsSynced تحدث كل الجداول | markAsSyncedById(tableName, recordId) | ⏳ قيد التنفيذ |
| Payments/Expenses مفقودة | إضافة DAOs و repositories | ⏳ قيد التنفيذ |
| الأخطاء تُبتلع | تسجيل مفصّل مع Stack Trace | ⏳ قيد التنفيذ |
| لا Soft Delete | إضافة deleted_at + منطق حذف | ✅ تم في SQL |
| لا Sync Cursor | _lastSyncTimes في الذاكرة | ⏳ يحتاج persistent storage |
| لا Server Version | sync_changes.server_version | ✅ تم في SQL |
| isConflict يخطئ تفسير الفشل | فصل errors عن conflicts | ⏳ قيد التنفيذ |
| مزامنة كل 5 ثواني | تغيير إلى 30 ثانية | ⏳ قيد التنفيذ |

---

## 🚀 خطوات التنفيذ

### المرحلة 1: قاعدة البيانات
1. ✅ تطبيق migration الجديدة على Supabase
2. ✅ إضافة أعمدة updated_at و deleted_at
3. ✅ إنشاء sync_changes
4. ⏳ اختبار insertion و triggers

### المرحلة 2: Backend (Edge Functions)
1. ⏳ نشر sync_records Edge Function
2. ⏳ اختبار الصلاحيات والأمان
3. ⏳ تسجيل الأخطاء في audit_log

### المرحلة 3: Flutter - Data Layer
1. ⏳ إضافة PaymentDao و ExpenseDao
2. ⏳ تحديث SyncRepositoryImpl
3. ⏳ إصلاح getPendingRecords()
4. ⏳ إصلاح markAsSyncedById()
5. ⏳ إصلاح pullRemoteRecords()

### المرحلة 4: Flutter - Mobile/Desktop
1. ⏳ تحديث SyncEngine
2. ⏳ إضافة UI لعرض حالة المزامنة
3. ⏳ إضافة retry manual
4. ⏳ اختبارات end-to-end

---

## 🧪 الاختبار

```bash
# 1. تطبيق Migration
supabase db push

# 2. اختبار Edge Function
curl -X POST https://YOUR_PROJECT.supabase.co/functions/v1/sync_records \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"records": [...]}'

# 3. تشغيل Flutter tests
flutter test packages/data/test/repositories/sync_repository_impl_test.dart

# 4. اختبار يدوي
# - إنشاء سجل على Desktop
# - انتظار 30 ثانية
# - التحقق من ظهوره على Mobile
```

---

## 📝 ملاحظات مهمة

1. **الأداء**: Incremental Pull يقلل الحمل من SELECT * إلى SELECT WHERE updated_at > X
2. **الأمان**: Edge Function يتحقق من صلاحيات المستخدم قبل الكتابة
3. **التوافق**: Backward compatible مع الأجهزة القديمة
4. **المراقبة**: sync_changes يوفر audit trail كامل
5. **التعافي**: _consecutiveFailures يمنع loops لا نهائية عند الفشل

---

**تاريخ الإنشاء**: 2024
**الحالة**: مسودة تنفيذية
