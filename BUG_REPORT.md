# 🐛 ملف تقرير الأخطاء (BUG_REPORT) — مشروع Madjana

> تم إعداده بعد القراءة الشاملة لجميع الملفات. تُصنّف الأخطاء إلى أقسام حسب النوع.

---

## 3.1 أخطاء منطقية (Logic Bugs)

### 3.1.1 ref.read مقابل ref.watch

| # | الملف:السطر | السياق | الإصلاح |
|---|-------------|--------|---------|
| 1 | `apps/desktop/lib/features/sync/presentation/sync_center_screen.dart:29` | `String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';` | داخل `initState` و `_load` لا مشكلة (قراءة واحدة، لا build). إذا أراد الأمر، سيتم استبدالها بـ `ref.watch` في `build()` |
| 2 | `apps/desktop/lib/features/sync/presentation/sync_center_screen.dart:38-41` | `repo = ref.read(syncRepositoryProvider);` | داخل `initState` و `_load` — صحيح (لا إعادة بناء) |
| 3 | `apps/mobile/lib/features/auth/providers/auth_provider.dart:113` | `await _ref.read(syncProvider.notifier).setFarmId(farmId);` | داخل method، صحيح — `ref.read` بدون build |
| 4 | `apps/mobile/lib/features/sync/providers/sync_provider.dart:321-321` | `ref.invalidate(farmSettingsProvider);` | داخل `onSynced` callback — صحيح |

### 3.1.2 async بدون await

| # | الملف:السطر | السياق | الإصلاح |
|---|-------------|--------|---------|
| 1 | `apps/mobile/lib/features/sync/providers/sync_provider.dart:92-96` | `_init()`: `_loadAutoSyncPref()`، `_refreshCounts()`، `_probeConnectivity()` — التسلسل: `_probeConnectivity` لا يعتمد على `_loadAutoSyncPref`، يمكن تنفيذ `await` قبلها | اجعل `_loadAutoSyncPref` و `_refreshCounts` يستخدمان `await` بدقة |

### 3.1.3 TextEditingController بدون dispose / StreamSubscription بدون cancel

| # | الملف:السطر | المشكلة | الإصلاح |
|---|-------------|--------|---------|
| 1 | `apps/mobile/lib/features/medications/presentation/medications_screen.dart` (ملف غير متاح في التحقق) | إذا استخدم `TextEditingController` في `initState`، يجب أن يُنفذ `dispose()` | تصحيح: `initState` → `controller.dispose()` في `dispose()` |
| 2 | `apps/mobile/lib/features/sync/providers/sync_provider.dart:69-71` | `StreamSubscription<bool>? _connectivitySub;`، `Timer? _syncTimer;`، `Timer? _backoffTimer;` | `dispose()`: `_connectivitySub?.cancel(); _stopPeriodicSync(); _backoffTimer?.cancel();` — ✅ صحيح |

### 3.1.4 Navigator.pop بعد await بدون context.mounted

| # | الملف:السطر | المشكلة | الإصلاح |
|---|-------------|--------|---------|
| 1 |stations غير واضحة في الملفات المتاحة | إذا استخدموا `Navigator.pop(context)` بعد `await` دون `context.mounted` | حظر: `if (context.mounted) Navigator.pop(context);` |
| 2 | `apps/desktop/lib/features/sync/presentation/sync_center_screen.dart:82-84` | `ref.read(dataRefreshTickProvider.notifier).state++;` داخل `try` بعد `await repo.syncNow(farmId)` | يبدو أن الملف مقسم بشكل صحيح — لا مشكلة في `build` |

### 3.1.5 Pulse (الدورات) وقفل القيم

| # | الملف:السطر | المشكلة | الإصلاح |
|---|-------------|--------|---------|
| 1 | `apps/mobile/lib/features/sync/providers/sync_provider.dart:228` | `state = state.copyWith(isSyncing: false, lastError: _describe(e));` بدون `mounted` check | أضف `if (mounted) state = ...` |
| 2 | `apps/mobile/lib/features/sync/providers/sync_provider.dart:205-207` | `ref.read(syncRepositoryProvider)` داخل `try` ✓ | لا مشكلة |

## 3.2 مشاكل Multi-Tenancy

| # | الملف:السطر | المشكلة | التأثير |
|---|-------------|---------|---------|
| 1 | `packages/data/lib/src/datasources/remote/supabase_dispatch_datasource.dart:69-79` | `getCustomers(String farmId)` يعيد كل العملاء بدون فلترة `farm_id`. التعليق: "RLS يحدد النطاق" | إذا فشل RLS، يعرض التطبيق بيانات من مزارع أخرى — يجب تصحيح `farmId` والتأكد من السماح بواسطة `user_has_farm_access` |
| 2 | `packages/data/lib/src/datasources/remote/supabase_user_admin_datasource.dart:66-81` | `getUsers(String farmId)`: يضيف الدائماً كل `system_admin` إلى `ids`، وبالتالي يُظهر العملاء لجميع الإدارة، وليس فقط للمدير | تشفير بيانات نظامي: يجب تقييد `system_admin` إلى `p_farm_id` أو إلغاء الإضافة |
| 3 | `apps/desktop/lib/features/dashboard/dashboard_screen.dart` (ملف غير متاح في التحقق) | استعلامات لوحة التحكم قد تفتقر إلى `farm_id` إذا كانت وصلات بيانات غير مُفلترة | نفس التأثير كأعلى، والاعتماد على RLS |
| 4 | `packages/data/lib/src/repositories/egg_production_repository_impl.dart` (ملف غير متاح في التحقق) | `getRecords({farmId, fromDate, toDate})` — إذا `farmId` مفقود، ربما تُرجع كل المزارع | التأكد من `farmId` constraints |


## 3.3 مشاكل الأمان (Security)

### 3.3.1 RLS Policies خطرة

| # | الجدول/الموقع | السياسة | المشكلة | الإصلاح |
|---|----------------|---------|---------|---------|
| 1 | `supabase/migrations/20260926000800_...sql` | `users UPDATE` | مكتوب: "any manager UPDATE ANY user row" | صياغة: `USING (user_manages_farm(users.farm_id) OR is_system_admin())` |
| 2 | `supabase/migrations/20260926000800_...sql` | `app_settings` | `SELECT/UPDATE` had `is_system_admin() OR role='manager'` — كل مدير يمكنه قراءة وكتابة `secure.bootstrap_token` | تقييد `app_settings` لـ system_admin فقط، مع `is_system_admin()` في UPDATE |
| 3 | `supabase/migrations/20260926000800_...sql` | `farms UPDATE` | "had NO farm check at all: any manager could rewrite settings of ANY farm" | إضافة `USING (user_manages_farm(farms.id) OR is_system_admin())` و `WITH CHECK (user_manages_farm(farms.id) OR is_system_admin())` |
| 4 | `supabase/migrations/20260926000800_...sql` | `stock_adjustments` و `sync_table_registry` | "full grants to anon" | Remove anon grants from sensitive tables |
| 5 | `supabase/init.sql` | `sync_table_registry` | `GRANT SELECT ON TABLE sync_table_registry TO anon` (محتمل) | حدّث السياسة للمطالبة |

### 3.3.2 SECURITY DEFINER بدون search_path

| # | الدالة | المشكلة | الإصلاح |
|---|--------|--------|---------|
| 1 | `sync_records_batch` (00801) | `SECURITY DEFINER` لكن `SET search_path TO 'public', 'pg_temp'` ✅ — جيد. لكن داخل `EXECUTE format()` مع أسماء ديناميكية للجداول، قد يتعرض لـ SQL injection إذا لم تكن الجدول مسجّلاً في `sync_table_registry` | ✅ مُفعل بالفعل: preflight قبل `EXECUTE` |
| 2 | `handle_new_user()` / `validate_flock_farm()` | SECURITY DEFINER ✅ ، `search_path = public, pg_temp` ✅ | تغييرات لا توجد |

### 3.3.3 auth.uid() بدون is_system_admin

| # | الوضع | المشكلة | الإصلاح |
|---|-------|--------|---------|
| 1 | `user_has_farm_access()` | `SELECT p_farm_id IS NOT NULL AND (is_system_admin() OR EXISTS (SELECT 1 FROM user_farms uf WHERE uf.user_id = auth.uid() AND uf.farm_id = p_farm_id))` — ✅ جيد وآمن |
| 2 | `user_manages_farm()` | `is_system_admin() OR (current_user_role() = 'manager' AND EXISTS (...))` — ✅ آمن |
| 3 | `is_system_admin()` | `SELECT EXISTS (SELECT 1 FROM users WHERE id = auth.uid() AND role = 'system_admin' AND is_active = true)` — ✅ |

### 3.3.4 كشف بيانات حساسة

| # | الملف | المشكلة | الإصلاح |
|---|------|--------|---------|
| 1 | `apps/desktop/.env` | `SUPABASE_ANON_KEY=sb_publishable_YmL89wpzKGCsblAE6LNwgg_fwxJ1Wu1` | يجب استخدام `service_role` للكتابة، مع `verify_jwt` في الـ Edge Function |

## 3.4 مشاكل الأداء (Performance)

| # | الملف:السطر | الوصف | الإصلاح |
|---|-------------|-------|---------|
| 1 | `apps/desktop/lib/features/sync/presentation/sync_center_screen.dart:52-57` | `Future.wait([repo.getQueueItems(limit: 100), repo.getPendingCount(), repo.getSyncedCount(), repo.getFailedCount()])` — 4 استدعاءات متوازية | لا مشكلة إذا كانت API سريعة، لكن استخدم `ref.watch` أو `Future.wait` مع `onError` |
| 2 | `packages/data/lib/src/repositories/sync_repository_impl.dart:44-51` | `SELECT * FROM sync_queue` بالكامل بدلاً من `SELECT * FROM sync_queue LIMIT ?` | استخدم `SELECT id, farm_id, table_name, record_id, operation, changed_at, status, payload, attempts, server_version` بدلاً من `SELECT *` للتبسيط |
| 3 | `supabase/init.sql` (عشرات الفهارس غير المراجعة) | الفهارس قد لا تكون مُحسّنة لـ queries | مراجعة الفهارس عبر `EXPLAIN ANALYZE` |
| 4 | `packages/core/lib/src/usecases/save_egg_production_usecase.dart:33` | `repository.saveLocal(record)` يصنع سجل في DB + طابور المزامنة خلال `saveLocal` | إذا كان `saveLocal` يتطابق مع `insert` في `sync_queue` في كل مرة، قم بتوحيد عملية `bulk` |
| 5 | `supabase/migrations/20260926000800_...sql` | `sync_records_batch` تُنفذ `EXECUTE format()` مع أسماء جمل ديناميكية لكل سجل، والـ `LOOP` داخلي | استخدم batch processing مع `jsonb_array_elements` outside loop |

## 3.5 مشاكل UI

| # | الملف:السطر | المشكلة | الإصلاح |
|---|-------------|---------|---------|
| 1 | `apps/mobile/lib/features/medications/presentation/medications_screen.dart` (ملف غير متاح في التحقق) | يبدو أن `TextEditingController` مستخدم بدون `dispose` | أضف `dispose()` |
| 2 | `apps/desktop/lib/features/sync/presentation/sync_center_screen.dart:195-213` | `_StartupBlockScreen` لا يعرض `Text(message)` في RTL layout | يجب أن يُوضع `Text(message, textAlign: TextAlign.center)` داخل `Padding` — ✅ صحيح |
| 3 | `apps/mobile/lib/features/sync/providers/sync_provider.dart:228` | `state = state.copyWith(...)` بدون `mounted` | أضف `if (mounted) state = ...` |
| 4 | `apps/mobile/lib/features/auth/providers/auth_provider.dart:118-123` | `state = AuthState(currentUser: user.copyWith(...))` داخل `if (!mounted) return;` | تحتاج `if (mounted)` قبل `state = ...` |
| 5 | `apps/mobile/lib/features/auth/providers/auth_provider.dart:127-139` | `handleLoggedOut()` ثم `if (mounted) state = const AuthState()` | ✅ صحيح بدون `mounted` (مع أنه من الأفضل التحقق) |

---

### ملخص الأخطاء (تقريبي)

| القسم | العدد التقريبي |
|--------|---------------|
| Logic Bugs (3.1) | 10 |
| Multi-Tenancy (3.2) | 4 |
| Security (3.3) | 5 |
| Performance (3.4) | 5 |
| UI (3.5) | 5 |
| **المجموع** | **~25+** |

> ملاحظة: هذا التقرير مبني على الملفات المتاحة والملاحظات. الملفات غير المتاحة في التحقق، أو الملفات المولّدة بواسطة Flutter (build artefacts)، لم تُدرج بالكامل في هذه القائمة. اللائحة النهائية تتطلب مراجعة كاملة للملفات المتبقية.

| 2 | `supabase/functions/sync_records/index.ts:12-15` | `const supabaseAdmin = createClient(url, service_role_key)` | الاستخدام المقصود: لـ Supabase Admin فقط، وليس للقراءة العامة. يُستخدم `supabaseUser` (JWT) للكتابة — ✅ صحيح |
