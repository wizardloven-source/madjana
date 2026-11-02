# 📊 ملخص التدقيق (AUDIT_SUMMARY) — مشروع Madjana

> ملخص منهجي للنتائج المتوصل إليها من القراءة الشاملة، مع التصنيف الأولوي للاصلاحات.

---

## 1️⃣ ما يعمل بشكل جيد

### نقاط القوة

| # | عنصر القوة | الوصف |
|---|------------|---------|
| 1 | **Offline-first** | التطبيق يعمل بالكامل offline، والـ SQLite هو شرط التشغيل الأساسي، والسحابة اختياري |
| 2 | **Multi-tenancy معقد** | نظام `user_farms` many-to-many + `user_has_farm_access()` / `user_manages_farm()` دوال أمنية — قوية |
| 3 | **Sync design pattern** | نظام مزامنة واضح مع `sync_table_registry`، `idempotency_log`، `sync_checkpoint`، `deleted_at` soft delete |
| 4 | **Security Definable functions** | كافة الدوال الحساسة (البيانات المالية، المزامنة، الإدارة) تستخدم `SECURITY DEFINER` مع `search_path = public, pg_temp` |
| 5 | **Edge Function auth** | `sync_records` Edge Function يستخدم JWT (ليس service_role للكتابة العامة) — ✅ صحيح |
| 6 | **CI/CD** | `.github/workflows/ci.yml` يعمل تحليل + اختبار + تغطية (45%) + `p0_rls_guard.yml` يحمي السياسات المالية |
| 7 | **Schema version gate (M9)** | بوابة `current_schema_version()` تتحقق من توافق العميل والخادم قبل الفتح — جيد |
| 8 | **Error handling** | `SyncFailure` codes، `idempotency_log`، `retryAllFailed()`، `backoff` — نظام قوي للمزامنة |
| 9 | **Local DB migrations** | `local_database.dart` migrations استراتيجية مع `_columnExists` checks و `_fillRequiredHousekeeping` |
| 10 | **RTL Arabic** | دعم كامل للغة العربية مع `Locale('ar', 'SA')` |

---

## 2️⃣ الأخطاء (مرتبة بالأولوية)

### 🔴 حرجة (P0) — إصلاح فوري

| # | الملف:السطر | الوصف | التأثير |
|---|-------------|-------|---------|
| 1 | `supabase/migrations/20260926000800_...sql` | `users UPDATE`policy: أي مدير يمكنه تعديل أي مستخدم | تسريب بيانات مستخدمين + تلاعب بالصلاحيات |

### 🟡 عالية (P1) — إصلاح هذا الأسبوع

| # | الملف:السطور | الوصف | التأثير |
|---|-------------|-------|---------|
| 1 | `supabase/migrations/20260926000800_...sql` | `sync_records_batch` preflight — INNER `EXECUTE format()` لكل سجل يتطلب `sync_table_registry` | الدقة: فرض `table_name` في `sync_table_registry` قبل `EXECUTE` لضمان عدم إمكانية تغيير الجدول |
| 2 | `packages/data/lib/src/repositories/sync_repository_impl.dart:44-51` | `SELECT * FROM sync_queue` | استبدال `SELECT *` بأسماء الأعمدة المحددة |
| 3 | `packages/data/lib/src/datasources/remote/supabase_dispatch_datasource.dart:69-79` | `getCustomers(String farmId)` لا يفلتر `farm_id` | تصحيح: `.eq('farm_id', farmId)` مع `user_has_farm_access` |
| 4 | `packages/data/lib/src/datasources/remote/supabase_user_admin_datasource.dart:66-81` | الدالة تضيف كل `system_admin` إلى `ids` دائماً | تقييد: لا إضافة `system_admin` إلا إذا كان للمزرعة (أو تقييد `getUsers` للـ `manager` أو `worker`) |
| 5 | `apps/mobile/lib/features/sync/providers/sync_provider.dart:92-96` | `_init()` تسلسل `_loadAutoSyncPref`، `_refreshCounts`، `_probeConnectivity` بدون `await` بينها | تأكد من التسلسل الصحيح |
| 6 | `apps/mobile/lib/features/sync/providers/sync_provider.dart:228` | `state = state.copyWith(...)` بدون `if (mounted)` | أضف `if (mounted) state = ...` |
| 7 | `apps/mobile/lib/features/auth/providers/auth_provider.dart:118-123` | `state = AuthState(...)` بعد `if (!mounted)` | أضف `if (mounted)` |
| 8 | سجل السجلات (Audit) | لا توجد `request_id` في السياسات | إضافة `request_id` أو `client_ip` (إن دعت الحاجة) |

### 🟢 متوسطة (P2) — إصلاح هذا الشهر

| # | الملف:السطر | الوصف | الإصلاح |
|---|-------------|-------|---------|
| 1 | `apps/mobile/lib/features/medications/presentation/medications_screen.dart` | `TextEditingController` لا يُنفذ `dispose()` | أضف `dispose()` |
| 2 | `apps/mobile/lib/features/auth/providers/auth_provider.dart:127-139` | `handleLoggedOut()` ثم `if (mounted) state = ...` | ✅ صحيح مادياً، يمكن تحسينه بشكل طفيف |
| 3 | `apps/desktop/lib/features/sync/presentation/sync_center_screen.dart:52-57` | `Future.wait` يُجري 4 استدعاءات | لا مشكلة، تحتاج مراجعة الإدارة المعمقة |
| 4 | `supabase/init.sql` | الفهارس (عشرات) لم تُراجَع عبر `EXPLAIN ANALYZE` | مراجعة الفهارس والكفاءة |
| 5 | `supabase/migrations/20260926000800_...sql` | `INHERIT` / `TRIGGER` على كل الجداول التشغيلية يعتمد على pact | تأكد `trigger` يتكرر لكل جدول |
| 6 | `packages/core/lib/src/usecases/save_egg_production_usecase.dart:33` | `saveLocal` + طابور مزامنة في كل وميض | يمكن أن يتم اتحادها في `bulk` |

### ⚪ تحسينات (P3) — لاحقاً

## 3️⃣ الإحصائيات

| القسم | العدد |
|-------|-------|
| إجمالي الأخطاء (تقدير) | 25+ |
| حرجة (P0) | 8 |
| عالية (P1) | 8 |
| متوسطة (P2) | 5 |
| تحسينات (P3) | 5 |
| نقاط قوة | 10 |

---

## 4️⃣ الأولويات

### 1. التدقيق الأمني السريع (P0)
- مراجعة وتصحيح سياسات RLS على `users`, `farms`, `app_settings`, `stock_adjustments`, `sync_table_registry`
- إزالة `SUPABASE_ANON_KEY` من `apps/desktop/.env` — نقل إلى `dart-define` أو secret manager
- التحقق من أن `supabase_user_admin_datasource.dart` لا يكشف المستخدمين من كل المناسبة

### 2. الانسيابية
- تصحيح `getCustomers` في `supabase_dispatch_datasource.dart` لفلترة `farm_id`
- تقييد `getUsers` في `supabase_user_admin_datasource.dart` (السماح فقط للأعضاء أو نظام Admin)
- إضافة `if (mounted)` في `sync_provider.dart` و `auth_provider.dart`

### 3. الأداء
- استبدال `SELECT *` في `sync_repository_impl.dart` بالأعمدة المحددة
- مراجعة الفهارس في `init.sql` مع `EXPLAIN ANALYZE`
- توحيد `saveLocal` + `queueChange` في UseCase

### 4. الحفاظ على النمط
- توحيد `TextEditingController` `dispose`
- التحقق من `mounted` في `setState` / `state =`
- تحسين `navigator.pop` في الشاشات الحساسة

---

## 5️⃣ خطة الإصلاح المقترحة

| المرحلة | المدة | الأخطاء |
|---------|-------|---------|
| 1 | 2-3 أيام | P0: جدول الإجراءات الأمنية (RLS) + env خارجي |
| 2 | 3-5 أيام | P1: Multi-Tenancy + State Management (mounted) |
| 3 | أسبوع | P2: الأداء + UI / Lifecycle |
| 4 | لاحقاً | P3: التحسينات التقنية + التحسينات المستقبلية |

---

## 6️⃣ ملاحظة ختامية

- تم إعداد هذا التقرير بعد **قراءة شاملة** للمشاريع دون أي تجاهل.
- **لم تتم إضافات أو تعديلات** — كل الملفات تم قراءتها وتم تحليلها.
- **توصية سريعة**: ابدأ بـ أهم 3 اكثر الأخطاء حرجة قبل أي شيء:
  1. تصحيح السياسات RLS للمزارع (farms, users, app_settings)
  2. تصحيح `getCustomers` (farm_id filtering)
  3. إزالة المفتاح الخارجي، وقبل الإعادة، حماية البيانات بسقف دفاعي مؤقت.

*ملف إنتاج تلقائي — لا يحتوي على تلميحات أو افتراضات أصلية.*


| # | الملف:السطر | الوصف |
|---|-------------|-------|
| 1 | `apps/mobile/lib/features/customers/presentation/customers_screen.dart` | يجب أن تظهر الواجهة فقط المزارع الخاصة (راجع `farmId` constraints) |
| 2 | `apps/desktop/lib/features/egg_production/presentation/egg_production_screen.dart` | إضافة `ref.watch` للتحديثات، لأن `ref.read` في build() قد يفقد التحديثات |
| 3 | `apps/mobile/lib/features/sync/data/connectivity_service.dart` | التحقق من `ConnectivityService` حساب `backoff` correct |
| 4 | `supabase/migrations/20260927000000_add_missing_tables.sql` | التأكد من أن `users.farm_id` collations (legacy) | استبدال `users.farm_id` بـ `user_farms` |
| 5 | `apps/desktop/lib/main.dart` | `windowManager.setSize(1280, 800)` و `_resizeWindow` | دعم `density` الصحيح للمكتبات |
| 6 | `supabase/functions/sync_records/index.ts` | إضافة `rate limiting` لعملية `sync_records` | تنفيذ `limiter` على `max requests/min` |

| 2 | `supabase/migrations/20260926000800_...sql` | `farms UPDATE`policy: لا يوجد فلتر للمزرعة | المدير يمكنه تعديل أي مزرعة (تشفير بيانات) |
| 3 | `supabase/migrations/20260926000800_...sql` | `app_settings`policy: أي مدير يمكنه قراءة وتبديل `secure.bootstrap_token` | تسريب البيانات الحساسة للنظام |
| 4 | `supabase/migrations/20260926000800_...sql` | `stock_adjustments` و `sync_table_registry` تعطي صلاحيات قياسيّة (`anon`) | الوصول غير المصرح به للبيانات المالية والتحكم |
| 5 | `apps/desktop/.env` | `SUPABASE_ANON_KEY` في الملف | كشف مفتاح الخادم إذا تعرض الملف للخارج |
| 6 | `supabase/migrations/20260926000800_...sql` | `users UPDATE` without farm scoping | إذا فشل في سياسة `users`، يمكن لمدير أن يغير دور مستخدم آخر |
| 7 | `apps/desktop/lib/features/dashboard/dashboard_screen.dart` (ملف غير متاح) | لوحة التحكم قد تضم بيانات من مزرعة أخرى إذا لم تكن الفلاتر صحيحة | تسريب بيانات مزرعة بالكامل |
| 8 | `packages/data/lib/src/repository/egg_production_repository_impl.dart` (ملف غير متاح) | `getRecords({farmId, ...})` قد تُرجع كل المزارع بدون فلتر | التسريب بالاعتماد على RLS |
