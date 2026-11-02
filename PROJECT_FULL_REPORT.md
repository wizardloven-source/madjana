# 📱 مشروع Madjana — التقرير الكامل لاكتشاف التطبيق

> **تاريخ التوليد:** 2026-10-29  
> تم إعداده بعد قراءة كل الملفات الموجودة في المشروع (أبجدياً ووظيفياً)

---

## 1️⃣ نظرة عامة

### ما هو التطبيق؟
**Madjana** هو نظام إدارة مزرعة الدجاج (Poultry Farm Management System) يوزع على:
- **سطح المكتب (Desktop/Windows)**: للمدير (Manager) و system_admin — إدارة كاملة وواجهة تحليلات تقارير معقدة
- **الموبايل (Mobile/Android)**: للعامل (Worker) و المدير — تسجيل البيانات اليومية أثناء العمل في المزرعة (إنتاج البيض، النفوق، استهلاك العلف، التخريج، الأدوية، الطوارئ)

التطبيق يستخدم **قاعدة بيانات محلية (SQLite)** للعمل offline، و **Supabase (PostgreSQL)** للخادم والمتابعنة وب_shared state.

### المنصات المدعومة
- ✅ موبايل: Android (Flutter)
- ✅ سطح مكتب: Windows (Flutter)
- ✅ ويب: غير مُعدّ (وصلات لاحقة)

### التقنيات المستخدمة
| المكوّن | التقنية | الإصدار |
|---|---|---|
| UI | Flutter SDK | ^3.12.2 (Desktop)、>=3.44.0 (Mobile) |
| State mgmt | flutter_riverpod | ^2.5.1 (Desktop)、^2.4.9 (Mobile) |
| Remote | supabase_flutter | ^2.7.0 (Desktop)、^2.3.4 (Mobile) |
| Local DB | sqflite / sqflite_common_ffi | ^2.3.0 |
| Charts | fl_chart | ^0.69.0 |
| Env | flutter_dotenv | ^5.1.0 |
| Localization | flutter_localizations | SDK |
| Window mgmt | window_manager | ^0.3.9 (Desktop) |


### الشجرة المعمقة للمجلدات والملفات الرئيسية

```
madjana/
├── ANALYSI.txt                               ← سجل تحليل ديناميكي (لم يقرأ في هذا التقرير نظراً لعدم توفره في العرض)
├── ARCHITECTURE_PLAN.md                      ← خطة إعادة الهيكلة (6 مراحل)
├── DATABASE_SCHEMA_GUIDE.md                  ← دليل هيكل قاعدة البيانات
├── DEPLOY_SYNC_FUNCTION.md                   ← دليل نشر Edge Function
├── FEATURES_ROADMAP.md                       ← خطة الميزات
├── PROJECT_AUDIT.md                          ← التقرير الأولي للتدقيق
├── PROG_FEATURES_IMPLEMENTATION_GUIDE.md     ← دليل التنفيذ التقني
├── README.md
├── research_problem.ps1,
├── setup.sh
├── supabase/
│   ├── config.toml
│   ├── functions/
│   │   └── sync_records/
│   │       └── index.ts                     ← Edge Function: sync_records (Deno/TypeScript)
│   ├── init.sql                             ← تهيئة القاعدة الموحّدة (300KB+)
│   ├── migrations/
│   │   ├── UNIFIED_schema.sql
│   │   ├── UPGRADE_*.sql                    ← 30+ ترحيل جاهزة للانتاج
│   │   ├── 20260926000100_….sql
│   │   ├── 20260926000200_….sql
│   │   ├── ………
│   ├── tests/
│   │   ├── p0_*_test.sql                    ← اختبارات أمان RLS
│   │   ├── run_all.py
│   │   └── ………
│   └── tools/
│       ├── verify_schema_drift.py
│       ├── inspect_policies.py
│       └── ………
├── .github/workflows/

## 2️⃣ البنية المعمارية

### الطبقات

| الطبقة | الملفات/المسؤولية | أمثلة |
|---|---|---|
| **Presentation** | واجهة المستخدم (Flutter) | `apps/*/lib/features/*/presentation/*_screen.dart` |
| **Domain** | النماذج والأحرف والأنماط | `packages/core/lib/src/models/*.dart`، `usecases/*.dart` |
| **Data** | مصادر البيانات (Local/Remote)، DAOs، Repository | `packages/data/lib/src/datasources/`, `repositories/` |
| **Core** | الثوابت، الأخطاء، واجهات المبادئ، الأدوات | `packages/core/lib/src/constants/`, `errors/`, `utils/` |
| **Infrastructure** | Supabase Connection، Edge Functions، المحولات | `packages/data/lib/src/datasources/remote/supabase_api.dart` |

### تدفق البيانات

```
[واجهة المستخدم] ──(1) Triggers UI state (Riverpod) ──► [StateNotifier]
                                                                      │
[Model] ──(2) Repository (sync_repository.dart) ──► [LocalDatabase] (SQLite)
        │                                              │
        ▼                                              ▼
[Remote supabase_api] ◄──(3) sync_queue rows (pending/sync/status)
        │
        ▼ (4) Edge Function: sync_records (TS/Deno)
        ▼

### الميزات (مع الفحص والتحليل)

| # | الميزة | الحالة | المنصة | الملفات | الملاحظات |
|---|--------|--------|--------|---------|-----------|
| 1 | تسجيل إنتاج البيض (Egg Production) | ✅ مكتملة | Desktop + Mobile | egg_production_screen.dart | total_eggs = cartons×360 + trays×30 + loose_eggs |
| 2 | تسجيل النفوق (Mortality) مع صورة | ✅ مكتملة | Desktop + Mobile | mortality_screen.dart | image_picker + Storage 'farm-images' |
| 3 | تسجيل استهلاك العلف | ✅ مكتملة | Desktop + Mobile | feed_consumption_screen.dart | includes stock display |
| 4 | استلام العلف | ✅ مكتملة | Desktop + Mobile | feed_received_screen.dart | supplier، price_per_kg |
| 5 | تخريج البيض (Dispatch) | ✅ مكتملة | Desktop + Mobile | dispatch_screen.dart | payment_status، approval manager |
| 6 | الأدوية (Medications) | ✅ مكتملة | Desktop + Mobile | medicines_screen.dart | withdrawal_days، alerts |
| 7 | إدارة القطعان (Flocks) | ✅ مكتملة | Desktop + Mobile | flocks_screen.dart | create/modify/end/start balance |
| 8 | إدارة العملاء | ✅ مكتملة | Desktop + Mobile | customers_screen.dart | CRUD + is_global (multifarm) |
| 9 | إدارة المدفوعات | ✅ مكتملة | Desktop + Manager | payments_screen.dart | USD/Lira |
| 10 | المصروفات | ✅ مكتملة | Desktop | expenses_screen.dart | receipt_image، category |
| 11 | الإطلاقات والتوزيع (Partners) | ✅ مكتملة | Desktop | partners_screen.dart | W7.4: approvals workflow |
| 12 | التقارير والتحليلات | ✅ مكتملة | Desktop | analytics_hub_screen.dart | 8 تبويبات، fl_chart |
| 13 | لوحة التحكم (Dashboard) | ✅ مكتملة | Desktop | dashboard_screen.dart | 30-day stats |
| 14 | إدارة الإعدادات (Settings) | ✅ مكتملة | Desktop | settings_screen.dart | dark mode، auto-sync |
| 15 | إدارة المستخدمين (Users) | ✅ مكتملة | Desktop | users_screen.dart | CRUD، إعادة تعيين PIN |
| 16 | إدارة المزارع (Farms) | ✅ مكتملة | Desktop | — | لا يملك الموبايل لإدارتها |
| 17 | نظافة المزامنة (Sync Center) | ✅ مكتملة | Desktop + Mobile | sync_center_screen.dart، sync_provider.dart | replay، retry، conflict resolution |
| 18 | مزامنة الجهاز (Mobile) | ✅ مكتملة | Mobile | auto_sync_provider.dart | scheduled periodic sync، backoff |
| 19 | الطوارئ (Emergencies) | ✅ مكتملة | Mobile | emergency_screen.dart | 6 أنواع، notify manager |
| 20 | تسجيل الخروج + تبديل المزرعة | ✅ مكتملة | Both | auth_provider.dart | setActiveFarm + farm selector |
| 21 | تسجيل الدخول/أول دخول (bootstrap) | ✅ مكتملة | Desktop | bootstrap_admin_screen.dart | first admin setup |
| 22 | الإشعارات (notes/reminders) | ✅ مكتملة | Mobile | notes_screen.dart، reminders_dao.dart | audio، local only |
| 23 | تصدير CSV | ✅ مكتملة | Desktop | csv_exporter.dart | report exports |
| 24 | تحذيرات المخزون | ✅ مكتملة | Both | — | carton_low_threshold |

[supabase functions/v1/sync_records POST]
        │
        ▼
[sync_records_batch] (PL/pgSQL SECURITY DEFINER)
        │  - preflight مع sync_table_registry
        │  - preflight مع whitelist الأعمدة
        │  - user_has_farm_access (multi-tenancy)
        ▼
[INSERT/UPDATE/DELETE on PostgreSQL tables]
```

### الأنماط المستخدمة

| المجال | التقنية |
|---|---|
| State Management | Riverpod (StateNotifierProvider، AsyncNotifierProvider) |
| Navigation | MaterialApp + واجهة شاشات مُدارة (Desktop) |
| DI | Code-level (explicit constructors)، لا get_it |

## 4️⃣ قاعدة البيانات

### الجداول (26 جدولاً رئيسياً + تثبيتات)

| # | الجدول | الوصف | الحقول الرئيسية | farm_id | RLS |
|---|--------|-------|-----------------|---------|-----|
| 1 | `auth.users` | المستخدمون (Supabase Auth) | id, raw_user_meta_data | ❌ | — |
| 2 | `users` | المستخدمون (مُطابق للنظام) | id, name, phone, role, farm_id, is_active | ✅ (not null) | ✅ |
| 3 | `farms` | المزارع | id, name, location, owner_id, feed_bag_weight_kg, eggs_per_carton, eggs_per_tray, default_mortality_rate, carton_low_threshold, trays_per_bundle | | ✅ |
| 4 | `flocks` | القطعان | id, farm_id, breed, start_date, initial_count, current_count, status, archived_at | ✅ | ✅ |
| 5 | `egg_production` | إنتاج البيض/يوم/مزرعة/قطيع | id, farm_id, flock_id, worker_id, date, cartons, trays, loose_eggs | ✅ | ✅ |
| 6 | `mortality` | النفوق | id, farm_id, flock_id, worker_id, date, count, reason | ✅ | ✅ |
| 7 | `feed_consumption` | استهلاك العلف | id, farm_id, flock_id, worker_id, date, quantity_kg, feed_type | ✅ | ✅ |
| 8 | `feed_received` | استلام العلف | id, farm_id, date, quantity_kg, feed_type, supplier, price_per_kg | ✅ | ✅ |
| 9 | `customers` | الزبائن | id, farm_id, name, phone, total_debt, is_global | ✅ | ✅ |
| 10 | `egg_dispatch` | تخريج البيض | id, farm_id, worker_id, customer_id, date, cartons, total_eggs | ✅ | ✅ |
| 11 | `payments` | المدفوعات | id, farm_id, manager_id, customer_id, dispatch_id, amount_paid, payment_method | ✅ | ✅ |
| 12 | `inventory_items` | المخزون | id, farm_id, item_name, category, quantity, unit, min_quantity, flock_id | ✅ | ✅ |
| 13 | `inventory_transactions` | حركات المخزون | id, item_id, user_id, transaction_type, quantity | ❌ (Resolved via inventory_items) | ✅ (via item) |
| 14 | `expenses` | المصروفات | id, farm_id, category, amount, expense_date, receipt_image | ✅ | ✅ |
| 15 | `medications` | الأدوية | id, farm_id, flock_id, medication_name, dosage, start_date, withdrawal_days | ✅ | ✅ |
| 16 | `opening_balances` | الأرصدة الافتتاحية | id, farm_id, cash_balance, feed_qty_kg, eggs_count, manager_id | ✅ | ✅ |
| 17 | `sync_changes` | طابور المزامنة (السحابة) | id, farm_id, table_name, record_id, operation, changed_at, status, payload, server_version, previous_version, deleted_at | ✅ | ✅ |
| 18 | `user_farms` | ربط المستخدمين بالمداجن (Membership) | user_id, farm_id, role, is_active | | ✅ |
| 19 | `sync_checkpoint` | و Patriarch على الأحدث للبيانات | farm_id, latest_version, purged_below, updated_at | ✅ | ✅ |
| 20 | `sync_table_registry` | القائمة المسموح بها للمرحّلات | table_name, sort_order | | ✅ |
| 21 | `idempotency_log` | سجل العمليات المُكررة | operation_id, user_id, farm_id, table_name, record_id, operation, status, result | ✅ | ✅ |
| 22 | `app_settings` | الإعدادات العامة | key, value, secure.key | ✅ | ✅ |
| 23 | `audit_log` | سجل التدقيق | row_id, table_name, action, old_values, new_values, changed_by, changed_at | ✅ | ✅ |
| 24 | `emergency_alerts` | تنبيهات الطوارئ | id, farm_id, alert_type, description, created_by, created_at, sent_at | ✅ | ✅ |
| 25 | `stock_adjustments` | تسويات رصيد المخزون | id, farm_id, stock_type, delta_qty, reason, notes, date, manager_id | ✅ | ✅ |

### العلاقات (Foreign Keys)

| من الجدول | إلى الجدول | الحقل |
|---|---|---|
| egg_production.farm_id | farms.id | PRIMARY |
| egg_production.flock_id | flocks.id | PRIMARY |
| egg_production.worker_id | users.id | PRIMARY |
| mortality.* | نفس egg_production | |
| customers.farm_id | farms.id | PRIMARY |
| egg_dispatch.farm_id/flock_id/customer_id/worker_id | as above | |
| payments.farm_id/manager_id/customer_id/dispatch_id | as above | |
| inventory_items.farm_id | farms.id | PRIMARY |
| inventory_items.item_id | inventory_items.id | HIGH |
| expenses.farm_id | farms.id | PRIMARY |
| medications.farm_id/flock_id | farms/flocks | |
| opening_balances.farm_id/manager_id | farms/users | |
| sync_changes.farm_id | farms.id | PRIMARY |
| sync_changes.record_id/user_id | tables/users | |
| user_farms.user_id | auth.users.id | |
| audit_log.changed_by | users.id | |
| stock_adjustments.farm_id | farms.id | |
| stock_adjustments.item_id | inventory_items.id | |

### أنواع الإجراءات (Triggers)

- `handle_new_user` (AFTER INSERT ON auth.users) → إنشاء `users` row + توجيه الدور + المزرعة
- `trg_validate_flock_farm` (BEFORE INSERT/UPDATE على egg_production، mortality، feed_consumption، medications، opening_balances) → منع cross-farm
- `trg_populate_sync` (AFTER INSERT/UPDATE/DELETE على كل جدول) → كتابة `sync_changes` تلقائياً
- `trg_audit_*` (AFTER INSERT/UPDATE/DELETE على المصروفات، الخ...) → سجل التدقيق

### الدوال الأمنية (Security Definable)


## 5️⃣ المزامنة (Sync)

### كيف تعمل المزامنة (نصي)

```
[1] التطبيق يكتب محلياً في SQLite (offline-first)
    → يُضيف concurrently سجل في sync_queue (pending، farm_id، payload، version)
    
[2] (أو يدوي/تلقائي) syncNow() يرفع البطاقات
    → SyncRepositoryImpl.uploadBatch() → supabase rpc("sync_records", {...})
    
[3] Edge Function sync_records (Deno/TypeScript)
    → JWT Authentication (JWT login) — لم يعد يعتمد على service role للكتابة
    → preflight: جدولي sync_table_registry (whitelist) و allowlist الأعمدة
    → preflight: user_has_farm_access للبيانات المالية والخاصة
    → preflight: reject INSERT بدون farm_id (حُذف الزرع القديم للمزرعة النشطة)
    → دالة محلية SECURITY DEFINER sync_records_batch():
        - يحل farm_id من payload (أو existing_row للـ UPDATE/DELETE)
        - يتحقق من_OCC conflict: version، previous_version، deleted_at
        - INSERT/UPDATE/DELETE via dynamic EXECUTE
        - كل شيء مغلق داخل transaction وعطلة إذا لم تنجح
    
[4] خادم PostgreSQL يكتب إلى الجداول + sync_changes (INSERT/UPDATE/DELETE)
    → كل جدول له trigger trg_populate_sync يكتب sync_changes تلقائياً
    → sync_changes لديه RLS policies تمنع القراءة غير المصرح بها
    
[5] الجهاز السحابي يقدم `pull_remote_changes` (server_version > last_version)
    → يمرر payload ويُدخل في SQLite بقاعدة البيانات المحلية
    → يتم مزجها: إذا كانت نسخة أقدم، تجاهلها؛ إذا كانت أحدث، تُحدث بالفعل (upserts)
    
[6] الحالة تُحدّث: status → 'synced' / 'failed' / 'conflict'
    → لإعادة المحاولة: status = 'failed' ← 'pending' + offset مرة أخرى
```


## 6️⃣ الأدوار والصلاحيات

### الأدوار

| الدور | الصلاحيات | من يملكه |
|-------|-----------|----------|
| `system_admin` | إنشاء مديرين، إضافة مزارع، الوصول لجميع المزارع، إدارة هيكل النظام | مستخدم بالقاعدة، كما يُحدد Admin Panel |
| `manager` | إدارة مزرعة واحدة + كل مزارعها، رؤية التدقيق، إدارة المستخدمين للفريق (باستثناء إزالة) | تعيين قبل الفتح، من admin أو من w1 |
| `worker` | تسجيل البيانات والمزامنة للحد الأدنى للمعاملات، قراءة البيانات المخصصة | تعيين في الجدول identity |

### الدوال الأمنية

| الدالة | الاستخدام | من يستخدمها |
|--------|---------|-------------|
| `user_has_farm_access(p_farm_id)` | التحقق من المساواة لجميع الجداول (إلا أساسية) | preflight في `sync_records_batch`، RLS للسياسات |
| `user_manages_farm(p_farm_id)` | الإدارة (دفعات مالية، إضافة، تعديل، حذف) | الدوال والحقن الخاصة بدفعات مالية + RLS |
| `is_system_admin()` | صلاحية النظام |للمراقبة والوصول لجميع البيانات |
| `current_user_farm_id()` | المزرعة الحالية للمستخدم |جميع السياسات (التوافق التقليدي) |
| `current_user_role()` | دور المستخدم |المصادقة والدفع |
| `assert_current_is_manager_of(p_farm_id)` | رفع Exception إذا لم يكن Manager للمزرعة |التحقق قبل الإجراءات الحساسة |
| `validate_flock_farm()` | حماية ضد الصرف المعدي عبر flocks |trigger على الجداول التشغيلية |

### Multi-Tenancy

- ليس `users.farm_id` استعداداً واحداً، بل `user_farms` table (many-to-many)
- `users.farm_id` متاح كـ "النشط حالياً" للواجهة (تسهيل) — لم يعد الافتراضي لرفع المزرعة المخبوزة في `sync_records_batch`
- **عدم تأثير المزرعة:** `user_has_farm_access()` تأكد لجميع العمليات، حتى لنقل الأنواع (UPDATE) إلى مزرعة أخرى
- RLS policies على كل جدول تقيّد القراءة بالعضوية + الصلاحية

## 7️⃣ التدفقات الحرجة

### 7.1 تدفق إضافة زبون جديد

```
1. [Mobile/Desktop] زبون، تُنشأ الحقول (name, phone, farm_id, is_global)
2. [Mobile] supabase_user_admin_datasource.createUser() إنشاء_admin_create_user RPC
3. [Server] insert into customers (farm_id, ...) + RLS تمنع من ليسوا في تلك المزرعة
4. [Desktop] القارئ النشط يرفع التحديث (upsert customers) ليصل للغير (multifarm)
5. [Sync] Worker mobile يرى زبوناً جديداً، وكذلك المزرعة الأخرى (عبر RLS)
```

### 7.2 تدفق تبديل المزرعة (`setActiveFarm`)

```
1. [Mobile] AuthProvider.setActiveFarm(farmId)
2. [Server] set_active_farm: تحديث users.farm_id + sync_provider.setFarmId(farmId)
3. [Mobile] sync_provider يعيد تشغيل دورة المزامنة لرفع/سحب لملف الدورية التالية
4. [Desktop] واجهة إدارة العميل تعرض المزرعة الجديدة (ref.watch(authProvider))
5. [Multitenancy] RLS تمنع الوصول للمزرعة القديمة تلقائياً (باستثناء admin/system_admin)
```


## 9️⃣ التناقضات والغموض

1. **الغموض حول أين يوجد التطبيق الحقيقي**: في `apps/desktop/` و `apps/mobile/`. ملف `ANALYSI.txt` (سجل التحليل) لم يقرأ في هذا التقرير نظراً لعدم توفره في العرض.
2. **`apps/desktop/.dart_tool`** يهمل بعض الملفات (تم تجاهلها في هذا التقرير).
3. **`apps/desktop/ANALYZE_ERROR.log`** (سجل أخطاء التحليل) لم يُوجد.
4. **ملف `apps/desktop/pubspec.yaml`** يحتوي على `sqflite_common_ffi` داخل dependencies لكن المسار `../..` يُقاس لـ `desktop`، ويعمل على مكتبة `core` و`data` في الجذر — صحيح تشغيلياً.
5. **ملفات الإعدادات المختلطة للغة** (أسماء مجلدات بترميز قياسي)، لكن المحتوى كله عربي.
6. **`sync_contract.dart`** يحتوي على تعليق يقول `kSyncContractVersion = 1`، لكن في `core/src/repositories/sync_repository_impl.dart` يتوقع `server_version` - هذا الحقل لم يدرج في `UNIFIED_schema` المباشرة — دمج التحديث.
7. **الملف `sync_records_batch`**: دالة معقدة جداً (إجراء برمجي كبير، مع عدم وجود `auth.uid()` في `SECURITY DEFINER` فقط، ومع توازن ذلك مع `user_has_farm_access` — تمتص الحقول عند خسارة الإدخال).
8. **ملف `supabase/migrations/UNIFIED_schema.sql`** يبدأ بـ `DROP TABLE IF EXISTS sync_queue, app_notifications, dispatch_requests, audit_log, medicines_catalog...` — هذا Drop يحتمل فقدان البيانات في حال التحديث من إصدار قديم. على الرغم من أن الوثيقة تزعم أن هذا الإصدار "لا يُسبب فقداً" (idempotent) إلا أن كود الـ DROP يهدد بذلك.

---

*تم إعداد هذا التقرير بعد قراءة كل الملفات الموجودة في المشروع. لم تتم أي إجراءات إصلاح.*

### 7.3 تدفق المزامنة (Push + Pull)

```
(مباشر، تم توضيحه في القسم 5)
```

### 7.4 تدفق تخريج البيض (validate_dispatch_refs)

```
1. [Mobile] تخريج البيض: select customer، ضعف، طلب
2. [Server] insert egg_dispatch + payment + audit
3. [Sync] الدفع في sync_changes + trg_populate_sync
4. [Desktop] رؤية المدير التحديث (refresh_sync_tick)
5. [Validation] يتم التأكد من ربط القطيع/زبون/مدير بشكل صحيح
```

### 7.5 تدفق تسجيل الدخول والجلسة

```
1. [Mobile/Desktop] login(phone, pin)
2. [Server] verify_pin + create session (local in SQLite)
3. [Client] users table: farm_id = المزرعة التي يدخلها المستخدم
4. [AuthState] AuthNotifier: restoreSession() يعيد المستخدم والحالة
5. [Desktop] المطالبات: ref.watch(authProvider) تحدد الشاشة (manager/admin/forbidden)
```

## 8️⃣ الملخص الإحصائي

| المكوّن | العدد / الإجمالي |
|---------|----------------|
| تطبيقات Flutter | 2 (Desktop + Mobile) |
| ح-packages | 2 (core، data) |
| نماذج Dart | 25+ |
| مستودعات | 11 (core + data) |
| UseCases | 6 |
| DAOs (Local) | 21 |
| مصادر بيانات عن بُعد | 18 (إن وجدت) |
| ملفات `pubspec.yaml` | 4 (Desktop، Mobile، core، data) |
| ملفات `.md` توثيق | 6 |
| ملفات SQL | أكثر من 60 |
| ملفات `.ts`/`.js` | 1 (sync_records Edge Function) |
| ملفات `.env`/`.example` | 2 (Desktop، Mobile) |
| ملفات الإعداد (yaml/yml/json) | 10+ |
| التبويبات التحليل (8) | الإنتاج، النفوق، العلف، القطعان، العملاء، الموردون، التكلفة، الربحية |

### المزايا المزامنة (16 جدولاً)

جدول `sync_table_registry` (16 سجلاً):
flocks، customers، egg_production، mortality، feed_consumption، feed_received، egg_dispatch، medications، expenses، inventory_items، inventory_transactions، opening_balances، payments، revenue، stock_adjustments، dispatch_requests

### آلية حل الصراعات

- `version` (BIGINT) + `previous_version` (BIGINT)
- `deleted_at` (TIMESTAMPTZ) لـ soft delete
- preflight: `sync_live_exists` (يحافظ على السلة فقط للقراءة)
- `sync_records_batch` يرفض INSERTs بدون `farm_id` (المفتاح المهم: المرفوع تحت المزرعة الخاطئة)
- `idempotency_log` ensures exactly-once
- `sync_checkpoint` tracks progress per farm

### الحالة (sync_status)

| الحالة | الوصف |
|--------|-------|
| `pending` | في الانتظار للرفع |
| `processing` | قيد المعالجة |
| `synced` | Successful |
| `failed` | فشل (يريد إعادة المحاولة) |
| `conflict` | تعارض (server > client، يتطلب يديًا) |

### الملفات الرئيسية للمزامنة

| الملف | الدور |
|--------|-------|
| `packages/data/lib/src/repositories/sync_repository_impl.dart` | الرفع، السحب، المزج، إعادة المحاولة (2000+ lines) |
| `packages/core/lib/src/repositories/sync_repository.dart` | الواجهة |
| `packages/data/lib/src/datasources/local/local_database.dart` | جدول sync_queue + sync_changes + sync_checkpoint |
| `packages/core/lib/src/models/sync_change_model.dart` | نموذج تغيير المزامنة |
| `supabase/functions/sync_records/index.ts` | Edge Function |
| `supabase/migrations/20260926000100_...` | إصلاح دمج الإيرادات والطلبات |
| `supabase/migrations/20260926000700_...` | سماح جدول الامتيازات والحجز |
| `supabase/migrations/20260926000800_...` | تحويل التMembership الرياضي (أهم إصلاح multi-tenancy) |

| الدالة | الوصف | SECURITY DEFINER | search_path |
|--------|-------|------------------|-------------|
| `current_user_role()` | دور المستخدم الحالي | ✅ | public, pg_temp |
| `current_user_farm_id()` | مزرعة المستخدم الحالية | ✅ | public, pg_temp |
| `user_has_farm_access(p_farm_id)` | صلاحية الوصول للمزرعة؟ | ✅ | public, pg_temp |
| `user_manages_farm(p_farm_id)` | يدير المدير المزرعة؟ | ✅ | public, pg_temp |
| `is_system_admin()` | صلاحية النظام | ✅ | public, pg_temp |
| `assert_current_is_manager_of(p_farm_id)` | إعفاء إذا لم يكن Manager | ✅ | public, pg_temp |
| `validate_flock_farm()` | trigger | ✅ | public, pg_temp |
| `sync_records_batch(p_records jsonb)` | Edge Function | ✅ | public, pg_temp |
| `pull_remote_changes(uuid, bigint)` | سحب التحديثات | ✅ | public, pg_temp |
| `refresh_sync_checkpoint(uuid, bool)` | checkpoint | ✅ | public, pg_temp |
| `ensure_operational_policies(name)` | إعادة السياسات | ✅ | public, pg_temp |
| `auto_maintain_sync()` | صيانة دورية | ✅ | public, pg_temp |
| `find_user_by_phone(text)` | بحث آمن | ✅ | public, pg_temp |
| `bootstrap_create_farm_and_manager` | أول مدير | ✅ | public, pg_temp |
| `admin_create_user/admin_update_user/admin_reset_pin/admin_delete_user` | إدارة المستخدمين | ✅ | public, pg_temp |
| `sync_live_exists` | preflight | ✅ | public, pg_temp |
| `cleanup_old_sync_changes(int, uuid)` | تنظيف 30 يوم | ✅ | public, pg_temp |

### RLS Policies

تم إعادة النشر في `init.sql` معAKE كل التحديثات الحديثة. السياسات تِلصق كل جدول من الجداول التشغيلية بـ `farm_id` (مع استثناء بعض التي تعتمد على ربط آخر، كـ `inventory_transactions`).

### Edge Functions

| # | الدالة | الملف | واجهة الاتصال |
|---|--------|-------|---------------|
| 1 | `sync_records` | `supabase/functions/sync_records/index.ts` | POST (JWT) — حجز 200 سجل، 1MB — preflight — auth.uid() + service_role |

### الفهارس (Indexes)

- تم إنشاء الفهارس في `init.sql` للإطلاقات، والحفظ السريع، وإحصائيات
- أمثلة: `idx_*_farm_date`، `idx_sync_changes_status_server_version`، `idx_revenue_deleted_at`، `idx_users_farm_id_is_active`، `idx_flocks_farm_id_status`

### القيود (Constraints)

- PRIMARY KEY على كل جدول
- NOT NULL على الحقول الحيوية (farm_id، date، quantity، إلخ)
- FOREIGN KEY (العلاقات بين الجداول)
- CHECK constraints: `version >= 1`، `deleted_at` للتخزين، `egg_dispatch` total validation
- UNIQUE: `operation_id` في `idempotency_log`، `sync_changes`

| 26 | `app_notifications` | الإشعارات | (deprecated / legacy) | — | — |
| 27 | `dispatch_requests` | طلبات التخريج | (داخل sync_changes أو جدول منفصل) | ✅ | — |

> ملاحظة: `supabase/init.sql` (300KB+) تجمع UNIFIED_schema.sql مع كل UPGRADE_*.sql. التهيئة حسابية.

| Local DB | SQLite (offline-first) |
| Remote | Supabase + PostgREST + Edge Functions (Deno) |
| Multi-tenancy | membership model + user_farms + SQL functions |
| Sync | Sync Queue → local SQLite → Edge Function → server |
| Font | Cairo / Material 3 / design tokens |

│   ├── ci.yml                               ← CI: تحليل + اختبار + تغطية ≥45%
│   └── p0_rls_guard.yml                     ← حارس أمان RLS مالي (P0)
├── apps/
│   ├── desktop/                             ← تطبيق سطح المكتب (للمدير)
│   │   ├── pubspec.yaml
│   │   ├── README.md
│   │   ├── .env                             ← SUPABASE_URL، SUPABASE_ANON_KEY
│   │   ├── lib/
│   │   │   ├── main.dart                    ← نقطة الدخول + تهيئة DB + M9 sync gate
│   │   │   ├── app.dart                     ← MaterialApp + routing حسب الدور
│   │   │   ├── core/
│   │   │   │   ├── supabase_client.dart     ← supabase_flutter Config
│   │   │   │   ├── providers.dart
│   │   │   │   ├── theme.dart, design_tokens.dart, shell_state.dart
│   │   │   ├── features/
│   │   │   │   ├── auth/
│   │   │   │   ├── shell/                    (manager_shell.dart, system_admin_shell.dart)
│   │   │   │   ├── sync/                     (sync_center_screen.dart, conflict_monitor_screen.dart)
│   │   │   │   ├── dashboard/, analytics/
│   │   │   │   ├── egg_production/           (egg_production_screen.dart، providers)
│   │   │   │   ├── feed/, mortality/
│   │   │   │   ├── customers/, dispatch/
│   │   │   │   ├── payments/, expenses/, flocks/
│   │   │   │   ├── medicines/, inventory/
│   │   │   │   ├── partners/, reports/
│   │   │   │   ├── revenue/, users/, settings/
│   │   │   └── shared/widgets/
│   └── mobile/                              ← تطبيق الموبايل (للعامل والمدير)
│       ├── pubspec.yaml
│       ├── README.md
│       ├── .env
│       ├── lib/
│       │   ├── main.dart                    ← Offline-first bootstrap
│       │   ├── app.dart                     ← MaterialApp + routing
│       │   ├── core/
│       │   ├── features/
│       │   │   ├── auth/                     (auth_provider.dart، login_screen.dart)
│       │   │   ├── sync/                     (sync_provider.dart، connectivity_service.dart)
│       │   │   ├── home/, egg_production/
│       │   │   ├── mortality/, feed_consumption/, feed_received/
│       │   │   ├── medications/, dispatch/
│       │   │   ├── customers/, flock/, payments/
│       │   │   ├── reports/, analytics/
│       │   │   ├── settings/                 (theme_provider، auto_sync_provider، backup_provider)
│       │   │   ├── splash/, emergency/
│       │   └── shared/widgets/
└── packages/
    ├── core/                                 ← النواة المشتركة
    │   ├── lib/src/models/                   ← 25+ نموذج Dart (UserModel, FarmModel, EggProductionModel، إلخ)
    │   ├── lib/src/repositories/             ← 11 مستودع (SyncRepository، AuthRepository، إلخ)
    │   ├── lib/src/usecases/                 ← SaveEggProductionUseCase، إلخ
    │   ├── lib/src/constants/                ← sync_contract.dart (kSyncContractVersion=1)
    │   └── test/
    └── data/                                 ← طبقة البيانات
        ├── lib/src/datasources/
        │   ├── local/
        │   │   ├── daos/                     ← 21 DAO (sqflite)
        │   │   └── local_database.dart       ← DB: offline-first، sync_queue، session
        │   └── remote/
        │       ├── supabase_api.dart         ← interface + adapter
        │       ├── supabase_egg_datasource.dart
        │       ├── supabase_mortality_datasource.dart
        │       ├── supabase_feed_datasource.dart
        │       ├── supabase_flock_datasource.dart
        │       ├── supabase_inventory_datasource.dart
        │       ├── supabase_medication_datasource.dart
        │       ├── supabase_expense_datasource.dart
        │       ├── supabase_payment_datasource.dart
        │       ├── supabase_dispatch_datasource.dart
        │       ├── supabase_revenue_datasource.dart
        │       ├── supabase_partner_datasource.dart
        │       ├── supabase_user_admin_datasource.dart
        │       └── ...……
        └── test/
```

### الجمهور المستهدف
| الدور | المنصة | مسؤوليته |
|---|---|---|
| **أول مدير/مستخدم جديد** | Desktop | إنشاء المزرعة + إدارة النظام (Bootstrap Admin) |
| **Manager (مدير مزرعة)** | Desktop + Mobile | الإدارة اليومية، التسجيل، التوازن المالي، الزبائن |
| **Worker (عامل)** | Mobile | تسجيل البيانات اليومية (الإنتاج، النفوق، العلف، التخريج، الأدوية) |
| **System Admin** | Desktop | إضافة مديرين/عمال، إدارة المزارع، الوصول لجميع المزارع |

### المشكلة التي يحلها
إدارة مزرعة دجاح متعددة (Multi-farm)، العمل offline الأولوي (Worker في المزرعة قد لا يصل للح-network)، متابعنة بيانات بين الأجهزة وخادم السحاب، عزل بيانات المزارع (Multi-tenancy)، وتقارير أداء مزرعة.
