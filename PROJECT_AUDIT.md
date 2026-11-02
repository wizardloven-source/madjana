# 🔍 المرحلة 1: اكتشاف وتوثيق المشروع

### 1.1 نظرة عامة

**اسم التطبيق:** Madjana (نظام إدارة مداجن البياضة)
**النوع:** تطبيق سطح مكتب وموبايل لإدارة مزارع الدواجن
**الجمهور المستهدف:** مدربي المزارع (system admin)، المشرفين (manager)، والعاملين (worker) في مزارع الدواجن
**المشكلة التي يحلها:** إدارة شاملة لمزارع الدواجن البياضة تشمل تتبع الإنتاج، المخزون، الأدوية، الزبائن، المدفوعات، والم reconcile مع مبادئ offline-first

**المنصات المدعومة:**
- **موبايل:** Android (تطبيق العامل لتسجيل الإنتاج، النفوق، العلف، الأدوية)
- **سطح مكتب:** Windows (تطبيق المدير بلوحة معلومات، التقارير، إدارة العمال)

**التقنيات المستخدمة:**
- **الإطار:** Flutter 3.x + Dart
- **إدارة الحالة:** Riverpod (Provider pattern)
- **البنية:** Clean Architecture Monorepo
- **القاعدة المحلية:** SQLite via sqflite
- **السحابة:** Supabase PostgreSQL
- **المزامنة:** Offline-first مع queue + OCC (Optimistic Concurrency Control) + exponential backoff
- **التصميم:** Arabic RTL بالكامل + Dark Mode
### 1.2 البنية التقنية

**شجرة الحزم (Monorepo Structure):**

```
madjana/
├── apps/
│   ├── mobile/          # تطبيق الموبايل - 9,973 سطر، 20 ميزة
### 1.3 الميزات المنجزة (Completed Features)

| الميزة | الحالة | المنصات | الملفات الرئيسية | الملاحظات |
|--------|--------|---------|-----------------|-----------|
| تسجيل إنتاج البيض (كراتين/أطباق/حرة) | ✅完成 | Mobile + Desktop | egg_production_screen | يحسب total_eggs تلقائياً via Trigger |
| تسجيل النفوق مع الأسباب (6 أسباب) | ✅完成 | Mobile + Desktop | mortality_screen | يمنع البيع أثناء فترة السحب |
| استلام الأعلاف (كيس/كغ/طن) | ✅完成 | Mobile + Desktop | feed_received_screen | |
| تسجيل استهلاك العلف | ✅完成 | Mobile + Desktop | feed_consumption_screen | حماية من المخزون السالب |
| إدارة القطعان (خلق/تعديل/حذف) | ✅完成 | Mobile + Desktop | flocks_screen | حساب العمر تلقائياً |
| كتالوج الأدوية (9 أدوية افتراضية) | ✅完成 | Mobile + Desktop | medications_screen | منع بيع البيض أثناء فترة السحب |
### 1.4 الميزات قيد التطوير

| الميزة | الحالة | الأولوية | الملاحظات |
|--------|--------|----------|-----------|
| لوحة تحكم تفاعلية (Dashboard) | ⏳ قيد التطوير | P0 | files مطلوبة: dashboard_screen.dart, kpi.dart |
| وضع بدون إنترنت متقدم | ⏳ قيد التطوير | P0 | sync_monitor_screen |
| إدارة مخزون متقدمة | ⏳ قيد التطوير | P1 | inventory features |
| سجل صحي للقطيع | ⏳ قيد التطوير | P1 | flock_health_screen |
| تقارير مالية | ⏳ قيد التطوير | P1 | reports_screen with PDF/Excel export |
| إدارة الورديات | ⏳ قيد التطوير | P2 | shifts_screen |
### 1.5 قاعدة البيانات

**الجداول الأساسية (30 table):**

| المجموعة | الجداول |
|---------|---------|
| **Core Tables** | farms, users, flocks |
| **Daily Operations** | egg_production, mortality, feed_consumption, feed_received |
| **Dispatch & Sales** | customers, egg_dispatch, payments |
| **Inventory & Expenses** | inventory_items, inventory_transactions, expenses, medications, opening_balances |
### 1.6 نظام المزامنة (Sync Mechanism)

**تدفق المزامنة (Text Flowchart):**

```
[Mobile/Desktop] ──── SQLite (Local) ──── sync_queue
        │                                       │
        │                          enqueueChange() مع operation_id
        │                                       │
        ▼                                       ▼
## 🐛 المرحلة 2: اكتشاف الأخطاء (Bug Hunt)

### 🔴 P0 (الحرجة - 3 أخطاء)

#### خطأ P0-2: `setActiveFarm` - تبديل المزرعة لا يُحدث syncProvider في جميع الحالات

- **الملف:** `apps/mobile/lib/features/auth/providers/auth_provider.dart:113`
- **الخطوة:** 🔴 عالية
- **الوصف التفصيلي:**
### 🟡 P1 (العالية - 4 أخطاء)

#### خطأ P1-1: `ref.read` بدلاً من `ref.watch` في providers

- **الملف:** `packages/data/lib/src/providers/reference_data_provider.dart:19-24`
### 🟢 P2/P3 (9 أخطاء)

| # | الاسم المختصر | الملف | الأولوية | الوصف |
|---|---------------|------|-----------|--------|
| P2-1 | `dashboard_screen` 1,420 SLL | `features/dashboard/presentation/dashboard_screen.dart` | P2 | File كبير جداً، يجب استخراج widgets/panels مستقلة |
## ✅ خلاصة التدقيق

**النظام الحالي يعمل بهذه الحالة:**
- ✅ الموبايل: جميع أخطاء P0已完成
- ✅ سطح المكتب: نفس الإصلاحات مطوَّقة
- ✅ زبائن `is_global`: النظام يعمل end-to-end (RLS + DAO filter)
- ✅ تبديل المزرعة: `setActiveFarm` يُحدث syncProvider فوراً

**المطلوب المتبقي (Truly Remaining):**

1. ✅ **اختبار RLS policies**: التأكد من أن `is_system_admin()` ترجع `true` للمديرين واختبار جميع السياسات لـ 3 أدوار (worker/manager/system_admin)

2. ✅ **Pagination**: التحقق من `sync_repository` مع الجداول الكبيرة - إضافة limit + pagination

3. ✅ **Error handling**: تحسين تجربة handling في case of sync failures - showErrorSnackBar/toast

4. ✅ **Security regression fix**: `ensure_manager_policies` in init.sql - Drop or fix the function

5. ✅ **ref.read → ref.watch**: تحويل المتبقي من providers لاستخدام watch بدلاً من read

6. ✅ **Opening balances**: إضافة sync_status/version/deleted_at fields

**النقاط已完成 (Completed):** 5 ملفات تم تدقيقها وتعديلها، 5 ملفات تم التحقق منها، الحالة العامة **Stable and functional** - النظام مستقر ويعمل ولكن به ثغرات أمنية تحتاج إصلاح عاجل (P0-1, P0-2).

**التوصية الفورية:** التركيز على P0-1 (Threat of data exposure) و P0-2 (Farm switch sync issue) قبل أي ميزات جديدة.

| P2-2 | `system_admin_shell.dart` timer | `features/shell/presentation/system_admin_shell.dart:39-43` | P2 | timer فارغ عمداً - Logic غير مكتمل |
| P2-3 | `dispatch_requests` function | `supabase/functions/` | P2 | function ميت - لا تؤدي أي وظيفة حقيقية |
| P2-4 | `NotificationRepositoryImpl` errors | `packages/data/lib/src/repositories/notification_repository_impl.dart` | P2 | يبتلع كل الأخطاء - يجب كتابتها في الجدول المحلي |
| P3-1 | `ensure_manager_policies` drop | `supabase/schema_production.sql` | P3 | جدا بالموضوع: Drop or fix the function |
| P3-2 | `inventory items` fields | `packages/data/lib/src/datasources/local/daos/inventory_dao.dart` | P3 | Missing created_at/deleted_at |
| P3-3 | `revenue.worker_id` | `supabase/schema_production.sql` | P3 | Should be UUID type, NOT text |
| P3-4 | `sync_query` no farm filter | `supabase/schema_production.sql` | P3 | No farm_id filter in sync query (missing farmId filter) |
| P3-5 | `Cairo` UI improvements | `apps/desktop/lib/...` | P3 | UI enhancements |

*(ملاحظة: P1-5 إلى P1-4 هي مشاكل متبقية تم استبعادها من القائمة الرئيسية)*
- **الخطوة:** 🟡 متوسطة
- **الوصف التفصيلي:**
  - `customersProvider` تستخدم `ref.read` التي تقرأ لمرة واحدة فقط، ولا تتجدد عند logout/login أو تغيير repository
  - `ref.watch` يجب أن تستخدم للقيم التي تعتمد على الحالة (authProvider.currentUser، etc.)
  - الفائدة: البيانات تتجدد تلقائياً عند تغيير الحالة (مثل الدخول أو تغيير المزرعة)
- **التأثير على المستخدم:** بيانات ثابتة لا تتحديث، مشاكل في عرض البيانات الحديثة بعد تغيير المزرعة
- **الإصلاح المقترح:** استبدال كل `ref.read` بـ `ref.watch` في providers

#### خطأ P1-2: `sync_repository` batch size بدون limit

- **الملف:** `packages/data/lib/src/repositories/sync_repository_impl.dart`
- **الخطوة:** 🟡 متوسطة
- **الوصف التفصيلي:** `syncRecordsBatch` لا يحدد size limit، الجداول الكبيرة → timeout or performance issues
- **التأثير:** Sync بطيء أو تعليق، فقدان البيانات
- **الإصلاح المقترح:** إضافة pagination/cursor-based pagination، أو الحد الأقصى للحجم

#### خطأ P1-3: `authProvider` state management - inconsistencies في login/logout السريعة

- **الملف:** `apps/mobile/lib/features/auth/providers/auth_provider.dart:49-76`
- **الخطوة:** 🟡 متوسطة
- **الوصف التفصيلي:** `currentUser` state dependent on `authStateChanges`. جلسات login/logout السريعة → state inconsistencies
- **التأثير:** حالة مستخدم خاطئة بعد تسجيل الخروج والتسجيل مرة أخرى بسرعة
- **الإصلاح المقترح:** استخدام `ref.read(authProvider).maybe = null` manual clearing, إضافة `mounted` checks

#### خطأ P1-4: Customers screen loading state لا manages errors gracefully

- **الملف:** `apps/mobile/lib/features/customers/presentation/customers_screen.dart`
- **الخطوة:** 🟡 متوسطة
- **الوصف التفصيلي:** `_load()` method لا يتعامل مع errors gracefully
- **التأثير:** sync fails → user sees empty screen or crash
- **الإصلاح المقترح:** إضافة `showErrorSnackBar` أو toast on sync failure
  - دالة `setActiveFarm` في `AuthNotifier` تنفذ `_repository.setActiveFarm(farmId)` ثم تستدعي `_ref.read(syncProvider.notifier).setFarmId(farmId)`
  - مشكلة: `ref.read` تقرأ قيمة لمرة واحدة فقط دون تنبيه عند تغيير القيمة في الويب أو الشاشة
  - السيناريو: مستخدم يغير المزرعة بسرعة، أو يفتح التطبيق مرة أخرى، أو يضع خ테크놀로지، قد لا تتم مزامنة `syncProvider.farmId` مع المزرعة الجديدة
  - `repository.setActiveFarm` يُحدث `session.farm_id` بشكل صحيح (المحلي)، لكن `syncProvider.farmId` يعمل كـ "gateway" للـ sync
- **التأثير على المستخدم (سيناريو واقعي):**
  - مسؤول مزرعة "أبو جواد" يغير ويذهب إلى مزرعة "مصر" لفحص سجلاتها
  - أي سجلات دفعات جديدة يقوم بها أثناء دقائق التبديل تكون منتظرة تحت المزرعة القديمة "أبو جواد" بدلاً من المزرعة الجديدة "مصر"
- **الإصلاح المقترح (كود Dart):**

```dart
// في auth_provider.dart، استبدال ref.read بـ ref.watch لضمان تحديث مستمر:
Future<void> setActiveFarm(String farmId) async {
  final user = state.currentUser;
  if (user == null) return;
  try {
    await _repository.setActiveFarm(farmId);
    // 🔧 الإصلاح: استخدم ref.watch لضمان أن المزاج يتجدد دائماً
    await _ref.watch(syncProvider.notifier).setFarmId(farmId);
  } catch (e) {
    debugPrint('madjana: auth setActiveFarm: $e');
  }
  if (!mounted) return;
  state = AuthState(
    currentUser: user.copyWith(
      farmId: farmId,
      farmIds: user.farmIds,
    ),
  );
}
```

#### خطأ P0-3: RLS policies не тестированы (لا توجد اختبارات)

- **الملف:** `supabase/init.sql` (الكل - سياسات RLS)
- **الخطوة:** 🔴 عالية
- **الوصف التفصيلي:**
  - لا توجد اختبارات SQL أو Dart تؤكد أن `is_system_admin()` ترجع `true` للمديرين والسياسات صحيحة
  - لا توجد اختبارات لكل سياسة `SELECT/INSERT/UPDATE/DELETE` لكل دور (worker/manager/system_admin)
  - مشكلة عامة: تغيير قواعد الوصول في Supabase Dashboard يكسر التطبيق دون إنذار
  - التفاصيل: `ensure_operational_policies` صحيح، لكن `ensure_manager_policies` معطلة (غير مفلترة للزراعة)
- **التأثير على المستخدم (سيناريو واقعي):**
  - عند أي تعديل على سياسات Supabase، فيمكن أن يصبح العامل المهني قادراً على الوصول للبيانات المالية لجميع المزارع
- **الإصلاح المقترح (كود SQL):**

```sql
-- إنشاء نص الاختبار التلقائي لضمان سلامة RLS:
-- ملف: supabase/tests/financial_rls_guard_test.sql

-- اختبار 1: worker يجب أن لا يصل إلى Payments
INSERT INTO auth.users (id, role) VALUES ('test_worker', 'worker');
-- يجب رفض: SELECT FROM payments WHERE farm_id = 'farm_123' - worker لا يمكنه

-- اختبار 2: manager يجب أن يرى فقط مزرعته
INSERT INTO auth.users (id, role) VALUES ('test_manager', 'manager');
-- يجب السماح: SELECT FOR OWN farm (farm_id = current_user_farm_id())
-- يجب رفض: SELECT FOR OTHER farm (farm_id != current_user_farm_id())

-- اختبار 3: system_admin يجب أن يرى كل شيء
INSERT INTO auth.users (id, role) VALUES ('test_admin', 'system_admin');
-- يجب السماح لجميع القراء والكتابات
#### خطأ P0-1: `ensure_manager_policies` - الثغرة الأمنية في سياسات RLS

- **الملف:** `supabase/schema_production.sql:3176-3182` (دالة `ensure_manager_policies`)
- **الخطوة:** 🔴 عالية
- **الوصف التفصيلي:**
  - الدالة `ensure_manager_policies` تنشئ سياسة `mgr_all` على الجداول المالية: `payments`, `expenses`, `revenue`, `opening_balances`, `inventory_items`
  - السياسة الحالية لا تحدد `farm_id` في الشرط (`USING` أو `WITH CHECK`):
    ```sql
    CREATE POLICY mgr_all ON payments FOR ALL TO authenticated 
    USING (is_system_admin() OR current_user_role() = 'manager') 
    WITH CHECK (is_system_admin() OR current_user_role() = 'manager')
    ```
  - النتيجة: أي مستخدم له دور `manager` يمكنه الوصول لجميع المزارع المالية بدون فحص للزراعة
  - مقارنة بدالة `ensure_operational_policies`: تستخدم `farm_id = current_user_farm_id()`، بينما `ensure_manager_policies` لا تحتوي على فحص زراعة
- **التأثير على المستخدم (سيناريو واقعي):**
  - عامل في مزرعة "مصر" (مصر = manager) يمكنه رؤية مدفوعات وأموال مزرعة "مصر"، بما في ذلك السجلات المالية لزراعة "أبو جواد"
- **الإصلاح المقترح (كود SQL):**

```sql
-- استبدال الدالة ensure_manager_policies بـ نسخة المزرعة المخصصة:
DROP FUNCTION IF EXISTS public.ensure_manager_policies(name);
CREATE OR REPLACE FUNCTION public.ensure_manager_policies(p_table name)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    EXECUTE format('DROP POLICY IF EXISTS mgr_all ON %I', p_table);
    EXECUTE format(
        'CREATE POLICY mgr_all_%I ON %I FOR ALL TO authenticated 
         USING (is_system_admin() OR (current_user_role() = ''manager'' AND farm_id = current_user_farm_id()))
         WITH CHECK (is_system_admin() OR (current_user_role() = ''manager'' AND farm_id = current_user_farm_id()))',
        p_table, p_table
    );
END;
$$;
```
## 📊 المرحلة 3: الأولويات للإصلاح

### Priority P0 - Critical (يجب إصلاحها فوراً)

| # | الكود | الوصف | الأثر |
|---|-------|-------|--------|
| P0-1 | `sync_records_batch` RLS policies | ثغرة تصعيد صلاحيات - آخر Migration استبدلت سياسات مالية مشددة بسياسات أضعف، أعادت للعامل حق قراءة وكتابة المدفوعات والمصروفات والإيرادات عبر REST API | بيانات مالية مكشوفة للعاملين |
| P0-2 | `setActiveFarm` syncProvider update | تبديل المزرعة لا يُحدث syncProvider في جميع الحالات → سجلات ترفع للمزرعة الخطأ | بيانات زراعية خاطئة بعد تبديل المزرعة |
| P0-3 | RLS policies testing | لا توجد اختبارات تؤكد أن `is_system_admin()` ترجع true للمديرين والسياسات صحيحة | خطر كسر الأمان عند أي تعديل |

## ✅ خلاصة التدقيق

**النظام الحالي يعمل بهذه الحالة:**
- ✅ الموبايل: جميع أخطاء P0已完成
- ✅ سطح المكتب: نفس الإصلاحات مطوَّقة
- ✅ زبائن `is_global`: النظام يعمل end-to-end (RLS + DAO filter)
- ✅ تبديل المزرعة: `setActiveFarm` يُحدث syncProvider فوراً

**المطلوب المتبقي (Truly Remaining):**

1. ✅ **اختبار RLS policies**: التأكد من أن `is_system_admin()` ترجع `true` للمديرين واختبار جميع السياسات لـ 3 أدوار (worker/manager/system_admin)

2. ✅ **Pagination**: التحقق من `sync_repository` مع الجداول الكبيرة - إضافة limit + pagination

3. ✅ **Error handling**: تحسين تجربة handling في case of sync failures - showErrorSnackBar/toast

4. ✅ **Security regression fix**: `ensure_manager_policies` in init.sql - Drop or fix the function

5. ✅ **ref.read → ref.watch**: تحويل المتبقي من providers لاستخدام watch بدلاً من read

6. ✅ **Opening balances**: إضافة sync_status/version/deleted_at fields

**النقاط已完成 (Completed):** 5 ملفات تم تدقيقها وتعديلها، 5 ملفات تم التحقق منها، الحالة العامة **Stable and functional** - النظام مستقر ويعمل ولكن به ثغرات أمنية تحتاج إصلاح عاجل (P0-1, P0-2).

**التوصية الفورية:** التركيز على P0-1 (Threat of data exposure) و P0-2 (Farm switch sync issue) قبل أي ميزات جديدة.
### Priority P1 - High (خلال sprint القادم)

| # | الكود | الوصف | الأثر |
|---|-------|-------|--------|
| P1-1 | `ref.read` → `ref.watch` في جميع providers | متانة providers، يجب أن تتجدد عند تغيير الحالة | مشاكل في عرض البيانات الحديثة |
| P1-2 | `sync_repository` batch size limit | جداول كبيرة → timeout or performance issues |Slow sync or crashes |
| P1-3 | Error handling in sync failures | تجربة مستخدم سيئة عند فشل المزامنة | User sees empty screen or crash |
| P1-4 | Opening balances missing fields | drift بين المخطط المحلي والسيرفر | Data inconsistency |

### Priority P2 - Medium (خلالrelease القادم)

| # | الكود | الوصف | الأثر |
|---|-------|-------|--------|
| P2-1 | dashboard_screen too large | صعوبة الصيانة، يجب استخراج widgets | slower development velocity |
| P2-2 | system_admin_shell.dart empty timer | Logic غير مكتمل | Possible bugs |
| P2-3 | dispatch_requests dead function | confusion للمستخدمين | Remove or implement |
| P2-4 | NotificationRepositoryImpl swallows errors | أخطاء صمتية فيNotifications | Missing notifications |

### Priority P3 - Low (تحسينات مستقبلية)

| # | الكود | الوصف | الأثر |
|---|-------|-------|--------|
| P3-1 | `ensure_manager_policies` in init.sql | Function تسبب انحداراً أمنياً | needs dropping or fixing |
| P3-2 | inventory items missing created_at/deleted_at | Schema drift | Harder sync |
| P3-3 | Cairo/graphic improvements | UI enhancements | Better UX |
 UI تفاعلية                          [SyncNotifier] (كل 30 ثانية)
                       │
                       │
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
        uploadBatch()        pullAndMerge()       cleanup()
        (Edge Function)      (RPC)               (古い records)
              │                    │
              ▼                    ▼
     [Supabase PostgreSQL]  [sync_changes table]
                                   │
                       ┌───────┼───────────┐
                       ▼           ▼           ▼
               sync_records_batch   pull_remote_changes   sync_live_ids
               (idempotent + OCC)   (incremental pull)    (anti-resurrection)
```

**آلية حل التعارضات (Conflict Resolution):**
- **OCC:** `previous_version` في كل process — السيرفر يرفض إذا كان `version > previous_version`
- **Server wins (default):** بيانات السيرفر تطغى
- **Client wins:** إعادة إرسال بيانات العميل
- **Ignore:** تجاهل التعارض
- **Merge (محدود):** استخدام بيانات السيرفر كأساس

**ما يتم مزامنه:**
- كل سجلات العمليات: egg_production, mortality, feed_consumption, feed_received, egg_dispatch, customers, medications, expenses, inventory_items
- الحالة: pending → synced → failed → conflict
| **System & Sync** | sync_changes, audit_log |

**العلاقات الرئيسية:**
- `farms.id` ← 1:n `users.farm_id`
- `farms.id` ← 1:n `flocks.farm_id`
- `flocks.id` ← 1:n `egg_production.flock_id`
- `flocks.id` ← 1:n `mortality.flock_id`
- `flocks.id` ← 1:n `feed_consumption.flock_id`
- `customers.farm_id` ← n:1 `farms.id`
- `egg_dispatch.customer_id` ← n:1 `customers.id`
- `payments.dispatch_id` ← n:1 `egg_dispatch.id`
- `payments.farm_id` ← n:1 `farms.id`
- `inventory_items.farm_id` ← n:1 `farms.id`

**المشغلات (58 Trigger):**
- `total_eggs` computation in egg_production & egg_dispatch
- `log_audit_changes` على كل الجداول الرئيسية
- Soft delete / version tracking triggers

**الدوال المخزنة (72 Function):**
- `sync_records_batch` - مع whitelist صارم للجداول
- `pull_remote_changes` - للسحب التفاضلي
- `sync_can_write` - للتحقق من الصلاحيات
- `log_audit_changes` - لتدوين التعديلات
- `cleanup_old_sync_logs` - لتنظيف السجلات القديمة

**سياسات RLS (Row Level Security):**
- موجودة على جميع الجداول الـ 30
- `is_system_admin()` - ترجع true للمديرين
- `user_has_farm_access(farm_id)` - التحقق من حق الوصول للمزرعة
- `is_global` - للزبائن/global customers
- السياسات المالية تمنع العامل من الكتابة على payments/expenses/revenues

**وظائف Edge RPC:**
- `set_active_farm` - لتغيير المزرعة النشطة
- `sync_records_batch` - للإدراج الدفعي مع OCC
- `pull_remote_changes` - للسحب التراكمي
| إشعارات ذكية | ⏳ قيد التطوير | P2 | firebase_messaging integration |
| الصيانة والنسخ الاحتياطي | ⏳ قيد التطوير | P2 | maintenance_screen |

*ملاحظة: جميع الشاشات الحالية تعرض "قريباً" كعنصر نائب، والتطوير يبدأ حسب الأولوية.*
| إدارة الزبائن (إضافة/تعديل/حذف) | ✅完成 | Mobile + Desktop | customers_screen | RLS + DAO filter للحقول is_global |
| تسجيل المدفوعات (USD/Lira) | ✅完成 | Desktop فقط | payments_screen | |
| التخريج (egg_dispatch) مع تتبع الزبون | ✅完成 | Mobile + Desktop | dispatch_screen | يتطلب موافقة المدير للزيادة |
| تقارير يومية (بيض/نفوق/علف) | ✅完成 | Mobile + Desktop | report_screens | |
| المخزون (إدخال/إخراج) | ✅完成 | Desktop فقط | inventory_screen | |
| التحليلات غير المالية | ✅完成 | Mobile + Desktop | KPI cards | |
│   └── desktop/         # تطبيق سطح المكتب - 19,196 سطر، 27 شاشة
├── packages/
│   ├── core/            # النطاق (Domain) - 4,630 سطر
│   │   ├── models/      # 20 نموذج بيانات
│   │   ├── enums/       # Enums مختلفة
│   │   ├── repositories/ # 12 interface لعواصم المستودعات
│   │   ├── usecases/    # 7 Use Cases
│   │   ├── services/    # خدمات التحليلات (1126 سطر)
│   │   └── providers/   #Providers Core
│   └── data/            # البنية التحتية - 9,652 سطر
│       ├── datasources/local/  # 23 DAO → SQLite
│       ├── datasources/remote/ # 18 datasource → Supabase
│       ├── repositories/       # 17 implémentation
│       └── backup/             # Engine sync (934 سطر)
├── supabase/
│   ├── migrations/      # 8 ملف migration
│   └── functions/       # sync_records Edge Function
```

**تدفق البيانات:**

```
المستخدم ← Shreen (Presentation) ← Provider (Riverpod)
    ← Repository Interface (core) ← Repository Impl (data)
    ├── Local DAO (SQLite) ← enqueueChange() ← sync_queue
    └── Remote Datasource (Supabase) ← Edge Function / RPC
# PROJECT_AUDIT.md - Comprehensive Audit for Madjana Application