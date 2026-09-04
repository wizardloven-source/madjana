# 📚 دليل هيكل قاعدة البيانات - Poultry Farm Management System

## نظرة عامة

هذا الدليل يشرح هيكل قاعدة البيانات الموحد للنظام. تم توحيد جميع ملفات الهجرة في ملف واحد رئيسي لضمان التطابق التام بين الكود وقاعدة البيانات على Supabase.

---

## 📁 ملف الهجرة الرئيسي

**الموقع:** `/workspace/supabase/migrations/001_master_schema.sql`

**الحجم:** 732 سطر (33KB)

**الإصدار:** 3.0

**التاريخ:** 2025-01-02

---

## 🗂️ الجداول (20 جدول)

### 1. الجداول الأساسية (Core Tables)

| الجدول | الوصف | الحقول الرئيسية |
|--------|-------|-----------------|
| `farms` | المزارع | id, name, location, phone |
| `users` | المستخدمين | id, email, role, farm_id, pin_hash |
| `flocks` | القطعان | id, farm_id, breed, start_date, initial_count, current_count |

### 2. جداول الإنتاج اليومي (Daily Operations)

| الجدول | الوصف | الحقول الرئيسية |
|--------|-------|-----------------|
| `egg_production` | إنتاج البيض | id, farm_id, flock_id, worker_id, date, cartons, trays, loose_eggs, total_eggs (computed) |
| `mortality` | النفوق | id, farm_id, flock_id, worker_id, date, count, reason |
| `feed_consumption` | استهلاك العلف | id, farm_id, flock_id, worker_id, date, quantity_kg, feed_type |
| `feed_received` | استلام العلف | id, farm_id, date, quantity_kg, feed_type, supplier, price_per_kg |

### 3. جداول التخريج والمبيعات (Dispatch & Sales)

| الجدول | الوصف | الحقول الرئيسية |
|--------|-------|-----------------|
| `customers` | الزبائن | id, farm_id, name, phone, total_debt |
| `egg_dispatch` | تخريج البيض | id, farm_id, worker_id, customer_id, date, cartons, total_eggs (computed), payment_status |
| `payments` | المدفوعات | id, farm_id, manager_id, customer_id, dispatch_id, amount_paid, payment_method |

### 4. جداول المخزون والمصروفات (Inventory & Expenses)

| الجدول | الوصف | الحقول الرئيسية |
|--------|-------|-----------------|
| `inventory_items` | المخزون | id, farm_id, item_name, category, quantity, unit, min_quantity |
| `inventory_transactions` | حركات المخزون | id, item_id, user_id, transaction_type, quantity |
| `expenses` | المصروفات | id, farm_id, category, amount, expense_date, receipt_image |
| `medications` | الأدوية | id, farm_id, flock_id, medication_name, dosage, start_date, withdrawal_days |
| `opening_balances` | أرصدة افتتاحية | id, farm_id, cash_balance, feed_qty_kg, eggs_count |

### 5. جداول النظام والمزامنة (System & Sync)

| الجدول | الوصف | الحقول الرئيسية |
|--------|-------|-----------------|
| `sync_changes` | طابور المزامنة | id, farm_id, table_name, record_id, operation, changed_at, status, payload |
| `dispatch_requests` | طلبات التخريج | id, farm_id, flock_id, customer_id, requested_cartons, status |
| `app_notifications` | إشعارات التطبيق | id, farm_id, title, message, type, is_read |
| `audit_log` | سجل التدقيق | id, farm_id, user_id, action, table_name, old_values, new_values |
| `medicines_catalog` | كتالوج الأدوية | id, name, manufacturer, default_withdrawal_days |
| `app_settings` | إعدادات التطبيق | id, setting_key, setting_value (JSONB) |

---

## 🔑 الفهارس (Indexes)

تم إنشاء 17 فهرس لتحسين الأداء:

```sql
-- فهارس الجداول الأساسية
idx_users_farm          ON users(farm_id)
idx_users_role          ON users(role)
idx_flocks_farm         ON flocks(farm_id)
idx_flocks_status       ON flocks(status)

-- فهارس جداول الإنتاج
idx_egg_production_farm_date    ON egg_production(farm_id, date DESC)
idx_egg_production_flock_date   ON egg_production(flock_id, date DESC)
idx_egg_production_sync         ON egg_production(sync_status) WHERE sync_status = 'pending'
idx_mortality_farm_date         ON mortality(farm_id, date DESC)
idx_feed_consumption_farm_date  ON feed_consumption(farm_id, date DESC)

-- فهارس المبيعات
idx_customers_farm              ON customers(farm_id)
idx_egg_dispatch_farm_date      ON egg_dispatch(farm_id, date DESC)
idx_payments_customer           ON payments(customer_id)

-- فهارس المخزون
idx_inventory_items_farm        ON inventory_items(farm_id)
idx_expenses_farm_date          ON expenses(farm_id, expense_date DESC)

-- فهارس المزامنة والتدقيق
idx_sync_changes_farm_status    ON sync_changes(farm_id, status) WHERE status = 'pending'
idx_sync_changes_changed_at     ON sync_changes(changed_at DESC)
idx_audit_log_farm              ON audit_log(farm_id, created_at DESC)
```

---

## ⚙️ الدوال المساعدة (Helper Functions)

### دوال الصلاحيات

```sql
current_user_farm_id()  -- Returns UUID: مزرعة المستخدم الحالي
current_user_role()     -- Returns TEXT: دور المستخدم (worker/manager/system_admin)
```

### دوال المزامنة

```sql
sync_records_batch(p_records JSONB, p_user_id UUID) 
  -- تعالج دفعة من السجلات وتعيدها: {success: [], failed: [], conflicts: []}

get_pending_sync_changes(p_limit INTEGER DEFAULT 50)
  -- تجلب السجلات المعلقة للمزامنة

mark_sync_records_as_synced(p_ids BIGINT[])
  -- تحدث حالة السجلات إلى 'synced'

cleanup_old_sync_logs(days_to_keep INTEGER DEFAULT 30)
  -- تحذف السجلات القديمة المعاد مزامنتها وتعيد عدد المحذوفات
```

### دوال التدقيق

```sql
audit_trigger_function()
  -- دالة محفز تسجل التغييرات في audit_log تلقائياً
```

---

## 🔒 سياسات الأمان (RLS Policies)

### نمط موحد للجداول التشغيلية

كل جدول تشغيلي لديه 4 سياسات:

1. **{table}_select**: القراءة للمستخدمين المصادق عليهم من نفس المزرعة
2. **{table}_insert**: الإدراج للمستخدمين المصادق عليهم لنفس المزرعة
3. **{table}_update**: التحديث للمستخدمين المصادق عليهم لنفس المزرعة
4. **{table}_delete**: الحذف **للمدير فقط** من نفس المزرعة

### سياسات خاصة

| الجدول | السياسة | الوصف |
|--------|---------|-------|
| `users` | users_select_self | المستخدم يرى بياناته فقط |
| `users` | users_select_same_farm | المدير يرى مستخدمي مزرعته |
| `sync_changes` | sync_changes_no_manual_modification | منع التعديل اليدوي (false) |
| `inventory_transactions` | inventory_transactions_manager | المدير فقط يدير المخزون |
| `medicines_catalog` | catalog_select | الجميع يقرأ، المدير يكتب |
| `audit_log` | audit_log_manager | المدير فقط يرى سجل التدقيق |

---

## 📊 الحقول المحسوبة (Computed Columns)

### total_eggs في egg_production و egg_dispatch

```sql
total_eggs = (cartons × 360) + (trays × 30) + loose_eggs
```

يتم حسابه تلقائياً بواسطة PostgreSQL ولا يحتاج تحديث يدوي.

---

## 🔄 حالات المزامنة (Sync Status)

جدول `sync_changes` يدعم 4 حالات:

| الحالة | الوصف |
|--------|-------|
| `pending` | السجل بانتظار المزامنة |
| `synced` | تمت المزامنة بنجاح |
| `failed` | فشلت المزامنة (يتطلب تدخل) |
| `conflict` | تعارض مع نسخة أحدث على الخادم |

---

## 🌱 البيانات الأولية (Seed Data)

يتم إضافة 3 إعدادات افتراضية عند إنشاء القاعدة:

```json
{
  "app_version": {"major": 1, "minor": 0, "patch": 0},
  "features": {"pro_enabled": false, "max_users": 10},
  "sync_batch_size": {"value": 50}
}
```

---

## 📝 كيفية الاستخدام للمبرمجين

### 1. فهم نموذج البيانات

```dart
// مثال: نموذج EggProduction
class EggProductionModel {
  final String id;
  final String farmId;
  final String flockId;
  final String workerId;
  final DateTime date;
  final int cartons;
  final int trays;
  final int looseEggs;
  // totalEggs يُحسب تلقائياً في قاعدة البيانات
}
```

### 2. التعامل مع المزامنة

```dart
// عند حفظ سجل جديد:
await localDb.insert('egg_production', record);
await syncChangesDao.insert(SyncChange(
  farmId: record.farmId,
  tableName: 'egg_production',
  recordId: record.id,
  operation: 'INSERT',
  payload: record.toJson(),
  status: 'pending',
));

// المزامنة تتم تلقائياً عبر SyncEngine
```

### 3. الاستعلام عن البيانات

```sql
-- مثال: إنتاج البيض الأسبوعي
SELECT 
  DATE_TRUNC('week', date) as week,
  SUM(total_eggs) as total_produced
FROM egg_production
WHERE farm_id = current_user_farm_id()
GROUP BY DATE_TRUNC('week', date)
ORDER BY week DESC;
```

---

## 🚀 خطوات النشر

### على Supabase Dashboard:

1. اذهب إلى **SQL Editor**
2. انسخ محتويات `001_master_schema.sql`
3. الصقها في المحرر
4. اضغط **Run** لتنفيذ الهجرة
5. تحقق من نجاح العملية

### التحقق من النجاح:

```sql
-- التحقق من وجود الجداول
SELECT COUNT(*) FROM information_schema.tables 
WHERE table_schema = 'public';

-- يجب أن تكون النتيجة: 20 أو أكثر
```

---

## 🛠️ الصيانة

### تنظيف السجلات القديمة

```sql
-- تشغيل دالة التنظيف (تحذف السجلات المعاد مزامنتها منذ أكثر من 30 يوم)
SELECT cleanup_old_sync_logs(30);
```

### مراقبة حجم القاعدة

```sql
SELECT 
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

---

## 📞 الدعم

للأسئلة أو المشاكل المتعلقة بهيكل قاعدة البيانات:

1. راجع هذا الملف أولاً
2. افحص ملف `001_master_schema.sql` للتفاصيل الكاملة
3. تحقق من سجل التدقيق (`audit_log`) لفهم التغييرات الأخيرة

---

**آخر تحديث:** 2025-01-02  
**الإصدار:** 3.0  
**الحالة:** ✅ مستقر وجاهز للإنتاج
