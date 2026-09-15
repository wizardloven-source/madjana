# Madjana Poultry Farm — Feature Implementation Roadmap

**تاريخ الإنشاء:** 2026-09-15
**الإصدار:** 1.0

---

## 1. الميزات الموجودة بالكامل (34 ميزة)

| # | الميزة | المجال | Platforms |
|---|--------|--------|-----------|
| 1 | تسجيل الإنتاج اليومي | الإنتاج | Mobile + Desktop |
| 2 | إنتاج كل قطيع/مزرعة | الإنتاج | Mobile + Desktop |
| 3 | البيض السليم/المكسور/المتسخ | الإنتاج | Mobile + Desktop |
| 4 | إجمالي الإنتاج + نسبة الإنتاج | الإنتاج | Mobile + Desktop |
| 5 | تسجيل النفوق + الأسباب | النفوق | Mobile + Desktop |
| 6 | نسبة النفوق + التنبيهات | النفوق | Mobile + Desktop |
| 7 | منع تجاوز عدد الطيور | النفوق | Mobile + Desktop |
| 8 | استلام الأعلاف | الأعلاف | Mobile + Desktop |
| 9 | استهلاك الأعلاف | الأعلاف | Mobile + Desktop |
| 10 | أنواع الأعلاف | الأعلاف | Mobile + Desktop |
| 11 | مخزون الأعلاف (محسوب) | الأعلاف | Mobile + Desktop |
| 12 | تسجيل اللقاحات والعلاجات | الصحة | Mobile + Desktop |
| 13 | فترة سحب الدواء (تنبيه) | الصحة | Mobile + Desktop |
| 14 | إدارة العملاء | المبيعات | Mobile + Desktop |
| 15 | Dispatch (بيع البيض) | المبيعات | Mobile + Desktop |
| 16 | المدفوعات + العملة | المالية | Mobile + Desktop |
| 17 | المصاريف + التصنيفات | المالية | Mobile + Desktop |
| 18 | إنشاء/تعديل/حذف القطعان | القطعان | Mobile + Desktop |
| 19 | نهاية دورة القطيع | القطعان | Mobile + Desktop |
| 20 | تسجيل الدخول + الجلسات | الأمان | Mobile + Desktop |
| 21 | تعدد المزارع + تبديل المزرعة | المزارع | Mobile + Desktop |
| 21 | صلاحيات worker/manager/system_admin | الأمان | Mobile + Desktop |
| 22 | Offline-first (كتابة محلية) | المزامنة | Mobile + Desktop |
| 23 | Sync Queue + Retry + Backoff | المزامنة | Mobile + Desktop |
| 24 | Idempotency + OCC | المزامنة | Mobile + Desktop |
| 25 | Conflict Detection | المزامنة | Mobile + Desktop |
| 26 | Pull from Supabase | المزامنة | Mobile + Desktop |
| 27 | RLS على جميع الجداول التشغيلية | الأمان | DB |
| 28 | RLS مع farm_id isolation | الأمان | DB |
| 29 | Trigger حساب total_eggs | الإنتاج | DB |
| 30 | Trigger تعديل current_count | النفوق | DB |
| 31 | Trigger حماية flock_farm | الأمان | DB |
| 32 | Trigger حماية role_change | الأمان | DB |
| 33 | sync_records_batch (Edge Function) | المزامنة | DB |
| 34 | pull_remote_changes (RPC) | المزامنة | DB |

---

## 2. الميزات الجزئية التي تحتاج إكمالاً (18 ميزة)

### 2.1 RLS payments/expenses بدون farm_id (P0-01)
- **المشكلة:** أي manager يمكنه قراءة/تعديل بيانات أي مزرعة
- **الملفات المتأثرة:**
  - `supabase/migrations/` — migration جديد لتعديل RLS
- **التنفيذ:**
  1. إنشاء migration جديد يحذف policies القديمة على `payments`, `expenses`, `opening_balances`, `inventory_items`
  2. إنشاء policies جديدة تضيف `farm_id = current_user_farm_id()` في WHERE clause
  3. استخدام `DROP POLICY IF EXISTS` + `CREATE POLICY` — لا `DROP TABLE`
- **معايير القبول:**
  - manager في مزرعة A لا يستطيع قراءة بيانات مزرعة B
  - system_admin يقرأ جميع المزارع

### 2.2 منع المخزون السالب في DB (P0-02)
- **الملفات المتأثرة:**
  - `supabase/migrations/` — trigger جديد
- **التنفيذ:**
  1. إنشاء trigger `prevent_negative_inventory` على `inventory_items`
  2. التحقق قبل UPDATE: `IF NEW.quantity < 0 THEN RAISE EXCEPTION`
- **معايير القبول:**
  - محاولة جعل quantity سالب عبر SQL تفشل

### 2.3 حماية فترة السحب (P0-03)
- **الملفات المتأثرة:**
  - `packages/core/lib/src/usecases/save_dispatch_usecase.dart`
  - `packages/data/lib/src/repositories/dispatch_repository_impl.dart`
- **التنفيذ:**
  1. في `SaveDispatchUseCase.save()`: جلب آخر medication record للقطيع
  2. التحقق من `withdrawal_days` — إذا كان التاريخ الحالي < `medication_date + withdrawal_days` → رفض مع رسالة خطأ
- **معايير القبول:**
  - محاولة بيع بيض أثناء فترة السحب تفشل
  - البيع بعد انتهاء فترة السحب ينجح

### 2.4 ConflictMonitorScreen (P0-04)
- **الملفات المتأثرة:**
  - `apps/desktop/lib/features/sync/conflict_monitor_screen.dart`
- **التنفيذ:**
  1. قراءة `ConflictRepository.getAllConflicts()`
  2. عرض جدول: table_name, record_id, status, date
  3. أزرار: server_wins / client_wins / ignore
  4. استدعاء `ConflictRepository.resolveConflict()` أو `ignoreConflict()`
- **معايير القبول:**
  - عرض جميع التعارضات
  - حل التعارض بـ server_wins يحذف السجل المحلي ويُزامَن
  - حل بـ client_wins يُعيد إرسال السجل

### 2.5 Merge Conflict Resolution (P0-05)
- **الملفات المتأثرة:**
  - `packages/core/lib/src/usecases/conflict_usecases.dart`
  - `packages/data/lib/src/repositories/conflict_repository_impl.dart`
- **التنفيذ:**
  1. تنفيذ `merge` في `ResolveConflictUseCase`
  2. منطق الدمج: استخدام `serverVersion > clientVersion` → server wins fields
  3. أو دمج حقول: server data + client fields_non_null
- **معايير القبول:**
  - لا يوجد `throw UnimplementedError`
  - Merge يُنجز بدون فقدان بيانات

### 2.6 DispatchRequest Sync (P0-06)
- **الملفات المتأثرة:**
  - `packages/data/lib/src/datasources/local/daos/dispatch_request_dao.dart`
  - `packages/data/lib/src/datasources/remote/supabase_dispatch_datasource.dart`
  - `packages/data/lib/src/repositories/dispatch_repository_impl.dart`
- **التنفيذ:**
  1. إضافة `enqueueChange()` في `DispatchRequestDao.insert/update/delete`
  2. إضافة `replaceFromRemote()` في DAO
  3. إضافة sync logic في DispatchRepositoryImpl
- **معايير القبول:**
  - dispatch_request يظهر في جميع أجهزة المزرعة

### 2.7 فلว الإنتاج الكاملة (P0-07)
- **الملفات المتأثرة:**
  - `supabase/migrations/` — trigger جديد
  - `packages/data/lib/src/datasources/local/daos/flock_dao.dart` (قد يحتاج)
- **التنفيذ:**
  1. إنشاء trigger `update_flock_count_full` يحسب:
     `current_count = initial_count + additions - mortality - sales - destroyed`
  2. إنشاء جدول `flock_movements` (id, farm_id, flock_id, type[addition/sale/transfer/destruction], count, date, notes)
  3. إضافة DAO + Repository + Remote Datasource لـ `flock_movements`
  4. إضافة UI في flock management: أزرار "إضافة طيور" / "بيع" / "نقل"
- **معايير القبول:**
  - `current_count` يتطابق مع المعادلة
  - لا يمكن جعل count سالب

---

### 2.8 إدارة الموردين (P1-01)
- **الملفات المتأثرة:**
  - `supabase/migrations/` — جدول جديد `suppliers`
  - `packages/data/lib/` — dao, datasource, repository
  - `packages/core/lib/` — model, repository interface
  - `apps/mobile/lib/features/suppliers/` — شاشة جديدة
  - `apps/desktop/lib/features/suppliers/` — شاشة جديدة
- **الجدول الجديد:**
  ```sql
  suppliers (id, farm_id, name, phone, address, notes, created_at, updated_at)
  ```
- **معايير القبول:**
  - CRUD كامل للموردين
  - ربط المورد بـ `feed_received.supplier_id` بدلاً من نص حر

### 2.9 فواتير الشراء + الذمم الدائنة (P1-02)
- **الملفات المتأثرة:**
  - `supabase/migrations/` — جداول جديدة
  - `packages/core/lib/src/models/purchase_invoice_model.dart`
  - `packages/data/lib/src/datasources/local/daos/purchase_dao.dart`
  - شاشات جديدة في Mobile و Desktop
- **الجدول الجديد:**
  ```sql
  purchase_invoices (id, farm_id, supplier_id, date, total_amount, amount_paid, currency, exchange_rate, status, notes, version, created_at, updated_at, deleted_at)
  ```
- **معايير القبول:**
  - إنشاء فاتورة شراء مرتبطة بمورد واستلام
  - تتبع المدفوعات لكل فاتورة
  - حساب الذمم الدائنة

### 2.10 كشف حساب العميل (P1-03)
- **الملفات المتأثرة:**
  - `apps/mobile/lib/features/customers/` — إضافة شاشة كشف حساب
  - `apps/desktop/lib/features/customers/` — إضافة تبويب كشف حساب
- **التنفيذ:**
  1. جلب جميع dispatches + payments للعميل
  2. عرض جدول: date, dispatch (cartons, amount), payment, balance
  3. حساب `total_debt` = sum(dispatches) - sum(payments)
- **معايير القبول:**
  - كشف حساب يتطابق مع `customers.total_debt`
  - تصدير PDF/CSV

### 2.11 ربط الاستلام بالمخزون (P1-04)
- **الملفات المتأثرة:**
  - `packages/data/lib/src/repositories/feed_repository_impl.dart`
  - `packages/data/lib/src/datasources/local/daos/inventory_dao.dart`
- **التنفيذ:**
  1. عند استلام علف: إنشاء `inventory_transaction` تلقائي (type=in, quantity=received_kg)
  2. عند صرف علف: إنشاء `inventory_transaction` تلقائي (type=out, quantity=consumed_kg)
  3. `inventory_items.quantity` يتم تعديله تلقائياً عبر trigger أو Dart code
- **معايير القبول:**
  - مخزون الأعلاف في `inventory_items` يتطابق مع `received - consumed`
  - كل حركة علف لها `inventory_transaction` مسجل

### 2.12 سجل صحي كامل للقطيع (P1-05)
- **الملفات المتأثرة:**
  - `apps/mobile/lib/features/flock/` — شاشة جديدة
  - `apps/desktop/lib/features/flock/` — تبويب جديد
- **التنفيذ:**
  1. جلب جميع: egg_production, mortality, feed_consumption, medications للقطيع
  2. عرض timeline: كل حدث بالتاريخ
  3. إحصائيات مجمعة: إنتاج، نفوق، علف، أدوية
- **معايير القبول:**
  - جميع الأحداث مرتبة بالتاريخ
  - إحصائيات دقيقة

### 2.13 خصم الدواء من المخزون (P1-06 + P1-07)
- **الملفات المتأثرة:**
  - `packages/core/lib/src/usecases/save_medication_usecase.dart`
  - `packages/data/lib/src/repositories/medication_repository_impl.dart`
  - `supabase/migrations/` — trigger جديد
- **التنفيذ:**
  1. جدول `medicine_inventory` (medicine_name, quantity, unit, expiry_date)
  2. عند تسجيل دواء: خصم الكمية من المخزون
  3. trigger يتحقق: إذا quantity < 0 → رفض
- **معايير القبول:**
  - لا يمكن صرف دواء بكمية أكبر من المخزون
  - المخزون ينقص تلقائياً بعد كل إعطاء

### 2.14 إدارة العمال في Mobile (P1-08)
- **الملفات المتأثرة:**
  - `apps/mobile/lib/features/workers/` — شاشة جديدة
  - `packages/data/lib/src/datasources/remote/supabase_user_admin_datasource.dart` (موجود)
- **التنفيذ:**
  1. إنشاء شاشة إدارة العمال في Mobile (مثل Desktop)
  2. CRUD عبر RPCs الموجودة
  3. عرض: اسم، هاتف، دور، المزرعة، الحالة
- **معايير القبول:**
  - إنشاء/تعديل/حذف عامل
  - تعيين لمزرعة

### 2.15 تقرير الربح والخسارة (P1-09)
- **الملفات المتأثرة:**
  - `packages/core/lib/src/services/` — service جديد
  - شاشات في Mobile و Desktop
- **التنفيذ:**
  ```
  الإيرادات = مبيعات البيض + مبيعات الطيور
  التكاليف = الأعلاف + الأدوية + المصاريف التشغيلية + العمال
  الربح = الإيرادات - التكاليف
  ```
- **معايير القبول:**
  - أرقام تتطابق مع البيانات الفعلية
  - يمكن تصديره

### 2.16 تقرير التدفق النقدي (P1-10)
- **الملفات المتأثرة:**
  - شاشات جديدة
- **التنفيذ:**
  1. جدول `cash_flow` أو حساب من payments + expenses + purchase_invoices
  2. عرض: inflows (مدفوعات العملاء) vs outflows (مدفوعات الموردين + المصاريف)
  3. رصيد剩餘
- **معايير القبول:**
  - يتطابق مع الإجماليات

### 2.17 تصدير PDF + Excel (P1-11, P1-12)
- **الملفات المتأثرة:**
  - `apps/mobile/lib/features/reports/` — إضافة تصدير
  - `apps/desktop/lib/features/reports/` — إضافة تصدير
  - `pubspec.yaml` — إضافة `pdf` و `excel` packages
- **التنفيذ:**
  1. Mobile: تصدير PDF باستخدام `pdf` package
  2. Desktop: تصدير Excel باستخدام `excel` package
  3. كلاهما: CSV موجود بالفعل في Mobile
- **معايير القبول:**
  - PDF يحتوي على جدول + إحصائيات
  - Excel يحتوي على أوراق عمل متعددة

---

## 3. الميزات غير الموجودة — خطوات التنفيذ

### Phase A: P0 Fixes (الأسبوع 1)

| # | الميزة | الملفات | الجداول الجديدة | RLS | Sync | Tests |
|---|--------|---------|-----------------|-----|------|-------|
| A1 | RLS farm_id لل المالية | migration | - | تعديل | - | SQL test |
| A2 | منع المخزون السالب | migration | - | - | - | SQL test |
| A3 | حماية فترة السحب | save_dispatch_usecase.dart | - | - | - | Unit test |
| A4 | ConflictMonitorScreen | conflict_monitor_screen.dart | - | - | - | Widget test |
| A5 | Merge resolution | conflict_usecases.dart | - | - | - | Unit test |
| A6 | DispatchRequest sync | dispatch_request_dao.dart, dispatch_datasource.dart | - | - | - | Unit test |
| A7 | فلوات الإنتاج الكاملة | migration + flock_dao.dart + flock_datasource.dart | flock_movements | RLS | Queue | Unit test |

### Phase B: P1 Critical Features (الأسبوع 2-3)

| # | الميزة | الملفات | الجداول الجديدة | RLS | Sync | Tests |
|---|--------|---------|-----------------|-----|------|-------|
| B1 | إدارة الموردين | suppliers_screen.dart + dao + datasource + model | suppliers | RLS | Queue | Unit + Widget |
| B2 | فواتير الشراء | purchase_* files | purchase_invoices | RLS | Queue | Unit |
| B3 | كشف حساب العميل | customer_statement_screen.dart | - | - | - | Widget |
| B4 | ربط الاستلام بالمخزون | feed_repository_impl.dart | - | - | - | Unit |
| B5 | السجل الصحي للقطيع | flock_health_screen.dart | - | - | - | Widget |
| B6 | خصم الدوى من المخزон | save_medication_usecase.dart + migration | medicine_inventory | RLS | Queue | Unit |
| B7 | إدارة العimators (Mobile) | workers_screen.dart | - | - | - | Widget |
| B8 | تقرير P&L | profit_loss_screen.dart + service | - | - | - | Unit |
| B9 | تقرير التدفق النقدي | cash_flow_screen.dart + service | - | - | - | Unit |
| B10 | تصدير PDF | pdf generation in reports | - | - | - | - |
| B11 | تصدير Excel | excel generation in reports | - | - | - | - |

### Phase C: P1 Infrastructure (الأسبوع 3-4)

| # | الميزة | الملفات | الجداول الجديدة | RLS | Sync | Tests |
|---|--------|---------|-----------------|-----|------|-------|
| C1 | Audit Log في Dart | audit_log_dao.dart + audit_log_repository.dart | - (table exists) | - | Queue | Unit |
| C2 | صلاحيات إدارة المستخدمين (Mobile) | workers_screen.dart CRUD | - | - | - | Unit |
| C3 | مصفوفة صلاحيات | enums.dart update | - | - | - | Unit |
| C4 | فلاتر المزرعة/العنبر/القطيع | UI updates | - | - | - | - |
| C5 | تقارير الصحة | health_report_screen.dart | - | - | - | Widget |
| C6 | تقارير المشتريات | purchase_report_screen.dart | - | - | - | Widget |
| C7 | منع التكرار في UseCase | save_egg_production_usecase.dart | - | - | - | Unit |
| C8 | بيع/إضافة/طرح الطيور | flock_movements_screen.dart | flock_movements | RLS | Queue | Unit + Widget |
| C9 | إغلاق اليوم التشغILI | day_close_screen.dart + service | - | - | - | Unit |
| C10 | FCR | feed_analytics.dart | - | - | - | Unit |
| C11 | أصناف Mobile | inventory_screen.dart | - | - | - | Widget |
| C12 | مقارنة المزارع | farm_comparison_screen.dart | - | - | - | Widget |

---

## 4. الجداول الجديدة المطلوبة

### 4.1 جدول `suppliers`
```sql
CREATE TABLE suppliers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  farm_id UUID NOT NULL REFERENCES farms(id),
  name TEXT NOT NULL,
  phone TEXT,
  address TEXT,
  notes TEXT,
  version BIGINT DEFAULT 1,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  deleted_at TIMESTAMPTZ
);
```

### 4.2 جدول `purchase_invoices`
```sql
CREATE TABLE purchase_invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  farm_id UUID NOT NULL REFERENCES farms(id),
  supplier_id UUID NOT NULL REFERENCES suppliers(id),
  date DATE NOT NULL,
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
  currency TEXT DEFAULT 'dollar',
  exchange_rate NUMERIC(8,2) DEFAULT 1,
  status TEXT DEFAULT 'pending',
  notes TEXT,
  version BIGINT DEFAULT 1,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  deleted_at TIMESTAMPTZ
);
```

### 4.3 جدول `medicine_inventory`
```sql
CREATE TABLE medicine_inventory (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  farm_id UUID NOT NULL REFERENCES farms(id),
  medicine_name TEXT NOT NULL,
  quantity NUMERIC(10,2) NOT NULL DEFAULT 0,
  unit TEXT DEFAULT 'ml',
  expiry_date DATE,
  version BIGINT DEFAULT 1,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

### 4.4 جدول `flock_movements`
```sql
CREATE TABLE flock_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  farm_id UUID NOT NULL REFERENCES farms(id),
  flock_id UUID NOT NULL REFERENCES flocks(id),
  type TEXT NOT NULL CHECK (type IN ('addition', 'sale', 'transfer', 'destruction')),
  count INTEGER NOT NULL CHECK (count > 0),
  date DATE NOT NULL,
  notes TEXT,
  worker_id UUID REFERENCES users(id),
  version BIGINT DEFAULT 1,
  created_at TIMESTAMPTZ DEFAULT now(),
  deleted_at TIMESTAMPTZ
);
```

### 4.5 جدول `environmental_readings` (P2)
```sql
CREATE TABLE environmental_readings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  farm_id UUID NOT NULL REFERENCES farms(id),
  section_no INTEGER,
  date DATE NOT NULL,
  temperature_c NUMERIC(5,2),
  humidity_percent NUMERIC(5,2),
  water_consumption_liters NUMERIC(10,2),
  notes TEXT,
  worker_id UUID REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT now()
);
```

---

## 5. التعديلات المطلوبة على RLS

### 5.1 payments — إضافة farm_id
```sql
-- حذف القديم
DROP POLICY IF EXISTS mgr_all ON payments;

-- إنشاء جديد مع farm_id
CREATE POLICY payments_manager_all ON payments
  FOR ALL
  USING (
    is_system_admin() OR
    (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
  );
```

### 5.2 expenses — نفس التعديل
```sql
DROP POLICY IF EXISTS mgr_all ON expenses;
CREATE POLICY expenses_manager_all ON expenses
  FOR ALL
  USING (
    is_system_admin() OR
    (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
  );
```

### 5.3 inventory_items — نفس التعديل
```sql
DROP POLICY IF EXISTS mgr_all ON inventory_items;
CREATE POLICY inventory_manager_all ON inventory_items
  FOR ALL
  USING (
    is_system_admin() OR
    (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
  );
```

### 5.4 opening_balances — نفس التعديل
```sql
DROP POLICY IF EXISTS mgr_all ON opening_balances;
CREATE POLICY opening_manager_all ON opening_balances
  FOR ALL
  USING (
    is_system_admin() OR
    (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
  );
```

---

## 6. التعديلات المطلوبة على المزامنة

### 6.1 DispatchRequest — إضافة sync
- إضافة `enqueueChange()` في `DispatchRequestDao`
- إضافة `sync_pending_dispatch_requests()` في `SyncRepository`

### 6.2 suppliers — sync جديد
- إضافة trigger `populate_sync_changes` على `suppliers`
- إضافة `sync_can_write('suppliers', 'manager')`

### 6.3 purchase_invoices — sync جديد
- إضافة trigger على `purchase_invoices`
- إضافة `sync_can_write('purchase_invoices', 'manager')`

### 6.4 medicine_inventory — sync جديد
- إضافة trigger على `medicine_inventory`
- إضافة `sync_can_write('medicine_inventory', 'manager')`

### 6.5 flock_movements — sync جديد
- إضافة trigger على `flock_movements`
- إضافة `sync_can_write('flock_movements', 'worker')` + `sync_can_read('flock_movements', 'worker')`

---

## 7. الاختبارات المطلوبة

### 7.1 Unit Tests (packages/core + packages/data)
| # | الاختبار | الملف |
|---|---------|-------|
| T1 | RLS farm_id isolation | SQL test |
| T2 | Negative inventory prevention | SQL test |
| T3 | Withdrawal period enforcement | save_dispatch_usecase_test.dart |
| T4 | Merge conflict resolution | conflict_usecases_test.dart |
| T5 | DispatchRequest sync roundtrip | dispatch_repository_test.dart |
| T6 | Flock count formula | flock_dao_test.dart |
| T7 | Duplicate egg production prevention | save_egg_production_usecase_test.dart |
| T8 | Cost per egg calculation | phase1_analytics_test.dart |
| T9 | Profitability calculation | phase1_analytics_test.dart |
| T10 | Supplier CRUD | supplier_repository_test.dart |
| T11 | Purchase invoice CRUD | purchase_repository_test.dart |
| T12 | Medicine inventory deduction | medication_repository_test.dart |
| T13 | Audit log recording | audit_log_repository_test.dart |

### 7.2 Widget Tests
| # | الاختبار | الملف |
|---|---------|-------|
| W1 | ConflictMonitorScreen displays conflicts | conflict_monitor_screen_test.dart |
| W2 | Supplier list + CRUD | suppliers_screen_test.dart |
| W3 | Purchase invoice creation | purchase_invoice_screen_test.dart |
| W4 | Customer statement display | customer_statement_test.dart |
| W5 | P&L report | profit_loss_screen_test.dart |
| W6 | Flock health timeline | flock_health_test.dart |

### 7.3 Sync Tests
| # | الاختبار | الملف |
|---|---------|-------|
| S1 | Multi-device conflict detection | sync_test.dart |
| S2 | Idempotency on duplicate push | sync_test.dart |
| S3 | Pull after local write | sync_test.dart |
| S4 | Tombstone propagation | sync_test.dart |

---

## 8. المخاطر المحتملة

| # | المخاطر | التأثير | التخفيف |
|---|---------|---------|---------|
| R1 | Migration قد يحذف بيانات في production | حرج | استخدام `DROP POLICY IF EXISTS` فقط — لا `DROP TABLE` |
| R2 | RLS قديم قد يمنع الوصول للمستخدمين الحاليين | عالي | اختبار على staging أولاً |
| R3 | Sync trigger جديد قد يسبب conflict مع sync القديم | متوسط | اختبار sync كامل |
| R4 | جداول جديدة قد تكسر RLS الحالي | متوسط | إنشاء RLS مع الجدول |
| R5 | كود Dart جديد قد يكسر Offline flow | متوسط | اختبار offline-first |
| R6 | تغييرات في UseCase قد تكسر التحقق الحالي | منخفض | اختبارات unit existente |

---

## 9. معايير القبول لكل ميزة

### معيار عام
- [ ] لا يوجد `throw UnimplementedError`
- [ ] لا يوجد hardcoded `farm_id` أو `user_id`
- [ ] لا يوجد demo data
- [ ] يدعم RTL
- [ ] يعمل Offline (إذا كان ممكناً)
- [ ] يدخل في Sync Queue
- [ ] يتحقق من الصلاحيات
- [ ] لا يكسر الميزات الموجودة
- [ ] dart analyze: 0 errors
- [ ] flutter analyze: 0 errors
- [ ] اختبارات الوحدة pass

### معيار P0
- [ ] لا يوجد bypass للحماية في قاعدة البيانات
- [ ] RLS يمنع الوصول غير المصرح به
- [ ] Conflict resolution يعمل بالكامل
- [ ] لا يمكن عمل count سالب

### معيار P1
- [ ] CRUD كامل
- [ ] Offline-first
- [ ] Sync working
- [ ] Arabic UI
- [ ] Error handling
- [ ] Loading states
- [ ] Empty states
- [ ] Form validation
