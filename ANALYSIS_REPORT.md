# التقرير التحليلي — نظام إدارة مزرعة دواجن بياض (YASeen Farm / مداجن)

**تاريخ التحليل:** 2026-10-02
**نطاق الفحص:** كامل مجلد المشروع (قراءة فقط — بدون أي تعديل)
**طريقة الفحص:** فحص ثابت للملفات + `flutter analyze` + `flutter test` + مراجعة SQL + تحقق يدوي من أسطر محددة

---

## 1. الملخص التنفيذي

هذا **نظام إنتاج حقيقي وكامل**، ليس نموذجاً أولياً (prototype). الكود مكتوب باحتراف ملحوظ، ومنظم كـ monorepo بـ Flutter، ويعمل بمبدأ **offline-first** حقيقي مع طبقة مزامنة متقدمة مبنية على التوفيق المتفائل (OCC) وسجل تغييرات (change log).

**الأرقام الحقيقية:**

| المؤشر | القيمة |
|---|---|
| أسطر Dart | 43,451 |
| ملفات Dart | 198 |
| ملفات SQL | 30 ملف ترحيل + `init.sql` (7,128 سطر) + مخططان |
| جداول على السيرفر | 30 |
| دوال Postgres | 72 |
| Triggers | 58 |
| Indexes | 41 |
| GRANT statements | 158 |
| جداول SQLite محلية | 28 (إصدار المخطط v29) |
| أخطاء ترجمة (`flutter analyze`) | **0** |
| تحذيرات ومعلومات | 150 (كلها `info`/`warning`) |
| اختبارات `packages/core` | 34/34 ناجحة |
| اختبارات `packages/data` | 177 ناجح / **2 فاشل** |

**الحكم العام:** النظام مبني بمهنية عالية ويصلح للاستخدام التشغيلي، لكن به **ثغرة تصعيد صلاحيات مؤكَّدة** أُحدثت في آخر هجرة للبيانات، إضافة إلى فجوات محاسبية معروفة لم تُعالج بعد.

---

## 2. البنية العامة (Architecture)

### 2.1 النمط المعماري

المشروع يتبع نمط **Clean Architecture مبسّط + Monorepo**:

```
┌─────────────────────────────────────────────────┐
│  apps/desktop   (Flutter Windows)  19,196 سطر  │  ← المدير
│  apps/mobile    (Flutter Android)   9,973 سطر  │  ← العامل
├─────────────────────────────────────────────────┤
│  packages/core   ← النطاق (Domain)   4,630 سطر │  ← مستقل تماماً عن Flutter UI
│    models/ enums/ repositories(interfaces)/     │
│    usecases/ services/ utils/                   │
├─────────────────────────────────────────────────┤
│  packages/data   ← البنية التحتية  9,652 سطر   │
│    datasources/local  (23 DAO → SQLite)         │
│    datasources/remote (18 datasource → Supabase)│
│    repositories (17 impl) / backup/             │
├─────────────────────────────────────────────────┤
│  supabase/  ← Postgres + RLS + Edge Function     │
└─────────────────────────────────────────────────┘
```

### 2.2 نمط التصميم داخل التطبيق

- **MVVM عبر Riverpod** — كل شاشة لها Screen (View) + Provider (ViewModel)، والـ ViewModels تستخدم `use cases` من `packages/core`، والـ use cases تتحدث مع `repository interfaces`، والتطبيقات توفر `repository impls`.
- **Clean Architecture boundaries mantqpovated فعلاً** — `packages/core` لا يستورد أي شيء من Flutter UI ولا من Supabase. هذا مهم لأن `packages/core` يُختبَر وحده (34 اختباراً ناجحاً بدون أي محاكاة شبكة).
- **Repository Pattern** — 17 واجهة في `core` و 17 تنفيذ في `data`. **لا يوجد أي واجهة بلا تنفيذ ولا أي تنفيذ بلا واجهة.**

### 2.3 الفصل الفعلي بين التطبيقين — ممتاز

| مسؤولية | Desktop | Mobile |
|---|---|---|
| إدخال الإنتاج/النفوق/العلف/الدواء | عرض ومراجعة | **الإدخال الفعلي** |
| إدخال التخريج | السعر + التحصيل | **الكمية فقط (لا حقول مالية إطلاقاً)** |
| المصروفات/الإيرادات/المخزون | كامل | **غير موجود** |
| التحليلات | 8 تبويبات كاملة | بطاقات KPI مبسطة |
| القطعان | معالجات إنشاء (3 خطوات) | عرض + إنشاء/إنهاء |
| طلبات التخريج | **الموافقة/الرفض** | **إنشاء الطلب** |
| ملاحظات العامل | غير موجود | **محلية 100% على الجهاز** |

هذا الفصل مدعوم على مستوى السيرفر أيضاً: `sync_can_write(role, table)` يمنع العامل من الكتابة على `expenses` / `payments` / `customers` / `flocks` / `inventory_items`.

---

## 3. التقنيات والإطارات

| الطبقة | التقنية | ملاحظات |
|---|---|---|
| الإطار | Flutter 3.44.8 stable | نفس الإصدار لكل الأجزاء |
| اللغة | Dart | — |
| إدارة الحالة | Riverpod (Provider/Notifier) | نمط `ConsumerWidget` / `Notifier` |
| التخزين المحلي | SQLite عبر `sqflite` | إصدار مخطط 29 |
| Backend | Supabase (Postgres + GoTrue + Storage + Edge Functions) | Deno/TypeScript لـ Edge Function |
| Edge Function | `supabase/functions/sync_records/index.ts` | طبقة تحقّق قبل RPC |
| الرسوم | `fl_chart` (Desktop) / رسوم يدوية (Mobile) | — |
| النماذج/النصوص | `intl` | RTL كامل، `ar` و `ar_SA` |
| CSV | مكتبة داخلية (Desktop) + `package:csv` (Mobile) | BOM UTF-8 لـ Excel العربي |
| الاختبارات | `flutter_test` + Fakes + harness SQLite | — |

**ملاحظة:** لا يوجد استخدام لـ PDF أو طباعة أو مشاركة على مستوى النظام — كل التقارير رسوم على الشاشة + تصدير CSV فقط.

---

## 4. خريطة الوحدات والشاشات

### 4.1 تطبيق سطح المكتب (28 شاشة)

التنقل عبر `NavigationRail` بعرض 230px، مجمّع في 7 أقسام (`manager_shell.dart:37-114`):

| # | الشاشة | العنوان | القسم | الوظيفة الأساسية |
|---|---|---|---|---|
| 0 | DashboardScreen | لوحة التحكم | الرئيسية | 12 استعلاماً متوازياً مع `try/catch` لكل واحد + رسوم اتجاه |
| 1 | AnalyticsHubScreen | التحليلات | الإنتاج | 8 تبويبات: إنتاج، نفوق، علف، قطعان، زبائن، موردون، تكلفة، ربحية |
| 2 | FlocksScreen | القطعان | الإنتاج | تجميع كل بيانات كل قطيع |
| 3 | EggProductionScreen | إنتاج البيض | الإنتاج | سجلات + فلاتر + CSV |
| 4 | MortalityScreen | النفوق | الإنتاج | سجلات + أسباب + CSV |
| 5 | FeedScreen | العلف | المبيعات والمالية | تبويبان: استهلاك / مستلم + تحويل أكياس↔كجم |
| 6 | DispatchScreen | التخريج والقبض | المتابعة | منطق الفوترة والدفعات الجزئية (1,232 سطر) |
| 7 | ApprovalsScreen | طلبات الموافقة | المتابعة | موافقة/رفض طلبات تخريج العامل (badge حي) |
| 8 | ExpensesScreen | المصروفات | المخزون | 9 فئات + تحويل عملة |
| 9 | InventoryScreen | المخزون | المخزون | CRUD + تعديلات مخزون + إسناد للقطعان |
| 10 | ReportsScreen | التقارير | المتابعة | تقارير KPI + CSV |
| 11 | MedicinesScreen | الأدوية | المخزون | كتالوج أدوية + فترة توقف |
| 12 | RevenueScreen | الإيرادات | المبيعات | دمج الإيراد اليدوي + إيراد بيع البيض |
| 13 | CustomersScreen | الزبائن | المتابعة | CRUD + زبائن عالميون |
| 14 | UsersScreen | المستخدمون | المتابعة | إدارة المستخدمين (مدير النظام) |
| 15 | SyncCenterScreen | المزامنة | المتابعة | عدّادات الطابور + إعادة محاولة + شاشة تعارضات منفصلة |
| 16 | SettingsScreen | الإعدادات | النظام | إعدادات المزرعة، العملة، النسخ الاحتياطي، تصدير شامل |
| 18 | EquipmentScreen | العدة والأجهزة | العدة | تجميع المخزون على مستوى القطيع |
| — | ConflictMonitorScreen | مراقبة التعارضات | (فرعية) | حل التعارضات يدوياً |
| — | FlockAccountingScreen | محاسبة القطيع | (فرعية) | P&L لكل قطيع |
| — | BarnRecordScreen | سجل الحظيرة | (فرعية) | آخر 7 أيام لكل حظيرة |
| — | NewFlockWizardScreen | معالج قطيع جديد | (فرعية) | خطوتان: بيانات + إنشاء حساب عامل |
| — | OldFlockWizardScreen | معالج قطيع قديم | (فرعية) | 3 خطوات + أرصدة افتتاحية |
| — | LoginScreen / BootstrapAdminScreen | دخول / إنشاء أول مدير | (فرعية) | — |
| — | SystemAdminShell | مدير النظام | (جذري) | 1,205 سطر — شِل منفصل كلياً |

### 4.2 تطبيق الموبايل (19 شاشة)

نقطة دخول واحدة (`HomeScreen`) بشبكة بطاقات — **لا يوجد شريط تنقل سفلي**:

| # | الشاشة | العنوان | الصلاحية | Offline |
|---|---|---|---|---|
| — | HomeScreen | الرئيسية | الكل | ✔ |
| 1 | EggProductionScreen | إدخال البيض | الكل | ✔ كامل |
| 2 | MortalityScreen | النفوق + كاميرا | الكل | ✔ كامل |
| 3 | FeedConsumptionScreen | استهلاك العلف | الكل | ✔ كامل |
| 4 | FeedReceivedScreen | استلام علف | الكل | ✔ كامل |
| 5 | DispatchScreen | تخريج البيض | الكل | ✔ (كمية فقط) |
| 6 | MedicationsScreen | الأدوية | الكل | ✔ كامل |
| 7 | NotesScreen | ملاحظاتي | الكل | ✔ **محلي 100%** |
| 8 | EmergencyScreen | بلاغ طارئ | الكل | ✔ صندوق صادر |
| 9 | SyncCenterScreen | مركز المزامنة | الكل | ✔ |
| 10 | NotificationsScreen | الإشعارات | الكل | جزئي |
| 11 | SettingsScreen | الإعدادات | الكل | ✔ |
| 12 | PaymentsScreen | قبض المبالغ | **مدير فقط** | ✔ |
| 13 | ReportsScreen | التقارير | **مدير فقط** | ✔ + CSV |
| 14 | AnalyticsScreen | التحليلات | **مدير فقط** | ✔ |
| 15 | FlockManagementScreen | إدارة القطعان | **مدير فقط** | ✔ |
| 16 | CustomersScreen | الزبائن | **مدير فقط** | ✔ |
| 17 | LoginScreen | دخول (رقم + PIN) | — | — |
| 18 | NoteComposer | محرر ملاحظة | الكل | ✔ |

**ملاحظة جودة:** `app_routes.dart` في الموبايل (8 ثوابت) **قديمة ومهجورة** — المسارات الحقيقية معرّفة مباشرة في `app.dart:50-69`. تُثلث الكود ولا يُستخدم.

---

## 5. نموذج البيانات والعلاقات

### 5.1 مخطط العلاقات النصي (السيرفر)

```
auth.users ──1:1──► public.users (role, phone, pin_hash, is_active)
                        │
                        │ M:N عبر user_farms (مصدر الحقيقة للعضويات)
                        ▼
                    public.farms ──1:N──► flocks
                        │                    │
                        │                    ├──1:N──► egg_production    (worker_id → users)
                        │                    ├──1:N──► mortality        (worker_id → users)
                        │                    ├──1:N──► feed_consumption (FK قابلة للـ NULL)
                        │                    ├──1:N──► feed_received    (FK قابلة للـ NULL)
                        │                    ├──1:N──► medications      (worker_id → users)
                        │                    ├──1:N──► opening_balances
                        │                    └──1:N──► flock_movements
                        │
                        ├──1:N──► customers ──1:N──► egg_dispatch ──1:N──► payments
                        │        (is_global)                                 (manager_id → users)
                        │
                        ├──1:N──► expenses            (مالية، على مستوى المزرعة)
                        ├──1:N──► revenue             (مالية)
                        ├──1:N──► stock_adjustments   (manager_id → users)
                        ├──1:N──► inventory_items ──1:N──► inventory_transactions
                        │            (flock_id اختياري)    (لا farm_id — يُحل عبر الصنف)
                        ├──1:N──► dispatch_requests     (بلا FK على farm/customer/flock)
                        └──1:N──► app_notifications

Sync: farms 1:1 sync_checkpoint
      farms 1:N sync_changes  (سجل append-only، تسلسل global_sync_version)
      عام:  idempotency_log, sync_table_registry, login_throttle, audit_log
```

### 5.2 مخطط العلاقات النصي (SQLite المحلي)

مرآة لـ 28 جدول. الجداول التي **لا تُزامن أبداً**: `worker_notes`, `worker_reminders`, `emergency_alerts`, `conflicts`, `sync_queue`, `sync_history`, `sync_state`, `session`, `app_settings`, `medicines_catalog`.

### 5.3 قواعد سلامة البيانات (Triggers)

النظامCoinspection بـ **35 قاعدة تحقق على مستوى قاعدة البيانات**، وهذا من أقوى نقاط التصميم:
- حساب `total_eggs` و `total_dispatch` آلياً
- `broken_eggs + dirty_eggs <= total_eggs`
- `amount_paid <= total_due`
- `count > 0` في النفوق، `quantity_kg > 0` في العلف
- `bags_count × 24 = quantity_kg` (استُبدل بـ trigger يقرأ من إعدادات المزرعة — `20260926000800:530`)
- منع المخزون السالب
- منع تصعيد صلاحيات المستخدم لنفسه
- تحديث `flocks.current_count` آلياً من النفوق/الحركات/الأرصدة الافتتاحية
- `total_debt` للزبون محسوب ومُحرَّس (غير قابل للكتابة المباشرة)

---

## 6. نظام الأدوار والصلاحيات — كما هو مطبق فعلياً

### 6.1 الأدوار الثلاثة

| الدور | التسمية | الوصف الفعلي |
|---|---|---|
| `worker` | عامل | إدخال تشغيلي فقط (إنتاج، نفوق، علف، تخريج كمية، دواء، بلاغ) |
| `manager` | مدير | كل شيء داخل مزرعته: مصروفات، إيرادات، مخزون، قبض، زبائن، قطعان، موافقات |
| `system_admin` | مدير النظام | إدارة المزارع والمستخدمين عبر كل المزارع |

**لا يوجد** دور `owner` أو `viewer` أو `cashier` أو `accountant`. كل شيء ثنائي: إما مدير أو عامل.

### 6.2 آلية المصادقة

- **Supabase GoTrue** ببريد اصطناعي: `<uid>@users.madjana.local`، وكلمة المرور = pepper + PIN (`supabase_auth_datasource.dart`).
- الدخول برقم الهاتف + **PIN من 4 أرقام** على التطبيقين.
- الجلسة محفوظة في `SessionDao` (جدول `session`) مع مسار استرجاع offline في `auth_repository_impl.dart:16-35`.
- **Desktop يمنع العامل منعاً تاماً**: `app.dart:46-55` — العامل يرى شاشة "هذا التطبيق مخصص للمدير فقط".

### 6.3 نموذج الصلاحيات — 4 طبقات

| الطبقة | الآلية | الفعالية |
|---|---|---|
| 1. اختبارات المنطق | `canViewFinancials` / `canEdit` / `isAdmin` في `enums.dart:20-27` | ✔ |
| 2. إخفاء الواجهة | `ManagerGate` على 5 مسارات + إخفاء في `HomeScreen` | جزئية ⚠ |
| 3. RPC المزامنة | `sync_can_write(role, table)` في `20260926000100:179-227` | ✔ فعّالة |
| 4. RLS | سياسات على 27+ جدولاً | ✔ **مع استثناء حرج — انظر 7.1** |

### 6.4 نموذج العضوية المتعدد للمزارع

`user_farms` (جدولjunction) هو **مصدر الحقيقة**. الدوال المساعدة (`20260926000800:48-100`):

- `user_has_farm_access(farm_id)` → عضو بصفته عامل أو مدير، **أو** مدير النظام
- `user_manages_farm(farm_id)` → مدير عضو، أو مدير النظام
- `user_farm_ids()` → كل مزارع العضوية، أو كل المزارع لمدير النظام

`users.farm_id` ما زالت موجودة كمرآة للمزرعة النشطة للتوافق.

---

## 7. نقاط الضعف والمشاكل — مرتبة بالخطورة

### 🔴 P0 — تصعيد صلاحيات مؤكَّد: العامل يستطيع قراءة وكتابة الجداول المالية مباشرة

**هذا أخطر ما وجدته، وهو ناقضٌ صريح لما يقوله `docs/SECURITY_AUDIT.md` نفسه** (الذي يذكر أن "Financial tables (manager-only)").

**السبب الجذري — تحققت منه يدوياً على أسطر الملفات:**

قبل آخر هجرة، كانت السياسات **مشددة بشكل صحيح**. في `init.sql:5141-5189`:

```sql
CREATE POLICY payments_manager_farm_scoped ON payments
  FOR ALL TO authenticated
  USING (is_system_admin() OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id()));
-- نفس الشيء لـ expenses, opening_balances, inventory_items, stock_adjustments
```

ثم migration `20260926000800_farm_membership_authorization.sql` **فعل ثلاثة أشياء خطرة**:

1. **أسقط كل السياسات** على 16 جدولاً في حلقة ت-destructive (`00800:254-261`) — بما فيها `payments`, `expenses`, `revenue`, `opening_balances`, `inventory_items`.
2. **أعاد إنشاءها** بشروط أضعف: قراءة/إدراج/تحديث بـ `user_has_farm_access(farm_id)` — وهي دالة تُرجع `true` لأي عضو في `user_farms` **(أي عامل أيضاً)** (`00800:48-64`).
3. **ترك `DELETE` فقط** بمتطلب المدير (`00800:298-300`).

النتيجة النهائية على الجداول المالية:

| العملية | قبل 00800 | بعد 00800 |
|---|---|---|
| SELECT | مدير فقط | **أي عامل عضو** ⚠ |
| INSERT | مدير فقط | **أي عامل عضو** ⚠ |
| UPDATE | مدير فقط | **أي عامل عضو** ⚠ |
| DELETE | مدير فقط | مدير فقط ✔ |

**قابلية الاستغلال:** المسار قابل للوصول من الـ REST API مباشرة، لا من مسار المزامنة فقط:
- `supabase_payment_datasource.dart:15,31,39,43` → `.from('payments').select/insert/update/delete`
- `supabase_expense_datasource.dart:15,30,35,39` → `.from('expenses')...`
- `supabase_revenue_datasource.dart:14,28,33,37` → `.from('revenue')...`

والصلاحيات تسمح بذلك: `init.sql:1139` يمنح `SELECT` لـ `authenticated`، و`init.sql:1161-1164` يمنح `INSERT, UPDATE, DELETE`.

**الأسوأ:** العامل لا يستطيع فعل ذلك عبر التطبيق (الواجهة تخفيه + `sync_can_write` يرفضه)، لكن الـ **anon key موجود داخل ملف `.env` الموزَّع مع التطبيق** — أي أن أي عامل (أو أي شخص يحصل على التطبيق) يستطيع فتح DevTools أو أي عميل HTTP وإرسال طلبات مباشرة بأهميته.

**تناقض داخلي إضافي:** `sync_can_write` في `20260926000100:179-201` **يستخدم فعلاً** المنطق الصحيح (يستبعد العامل من `payments`/`expenses`). أي أن التطبيق صار **أقوى** من قاعدة البيانات. القاعدة هي الطبقة الأضعف.

**لماذا لم تلتقطه الاختبارات؟** لا يوجد أي اختبار يق验证 أن RLS يرفض عاملاً — وهذا بالضبط ما حذّر منه `docs/TEST_COVERAGE_GAPS.md:77,124` (T3).

### 🟠 P1-1 — `dispatch_requests` معطّلة فعلياً من جهة العميل (وظيفة ميتة)

الطلب الذي يرسله العامل عند تجاوز المخزون **لا يُرفع أبداً**:
- `dispatch_request_dao.dart:10-26` — `insert()` يكتب في SQLite **ولا يستدعي `enqueueChange`**. لا يوجد أي استدعاء لـ `enqueueChange` في هذا DAO.
- لا يوجد `supabase_dispatch_request_datasource.dart` في `packages/data/lib/src/datasources/remote/`.
- العمودان المحليان مختلفان عن السيرفر: محلي `requested_cartons`/`requested_trays` مقابل سيرفر `cartons`/`trays`.

النتيجة: العامل يظن أن الطلب أُرسل ("تم إرسال الطلب إلى المدير (يُزامَن تلقائياً)"), وشاشة `ApprovalsScreen` لا تستقبل شيئاً.

### 🟠 P1-2 — وزن كيس العلف غير متّفق عليه في 4 أماكن مختلفة

| المكان | القيمة |
|---|---|
| `AppConstants.kgPerBag` (`app_constants.dart`) | **50.0** |
| `farms.feed_bag_weight_kg` (السيرفر، default) | **50** |
| `check_feed_consumption_mode` / `check_feed_received_mode` (السيرفر) | **24** |
| `feed_consumption_provider.dart` (موبايل) | **24** |
| Trigger `20260926000800:530` | يقرأ من المزرعة، احتياطي 24 |

يعني: **كل حساب استهلاك علف مسجَّل موجود في القاعدة على أساس 24 كجم، بينما التطبيق يعرض 50.** هذه ليست مشكلة نظرية — الأرقام المعروضة للمستخدم في التحليلات والتكاليف لا تطابق الأرقام المحفوظة.

### 🟠 P1-3 — مخططان متعارضان لـ PostgreSQL

- `schema_production.sql` (2026-09-06): لا يحتوي `flock_movements` ولا `sync_table_registry` ولا RLS على `idempotency_log`.
- `init.sql` (2026-09-19): يحتوي كل شيء.
- `migrations/20260926*.sql` (2026-09-26): **الأحدث والمُهيمن**، لكنه غير مدمج في `init.sql`.

`README.md:209-214` ينص على تطبيق `init.sql` أولاً ثم الـ migrations. لكن `init.sql` لا يحتوي `user_has_farm_access` إطلاقاً — فإذا أُعيد تطبيقه بعد الـ migrations لرجعت الأنظمة القديمة. **لا يوجد سجل ترحيل (migration history) واضح.**

### 🟡 P1-4 — تعارض merge غير منفّذ

`conflict_usecases.dart:75-80` يرمي استثناءً: `"Manual merge not implemented yet. Use client_wins or server_wins."` واجهة سطح المكتب تعالجه بتغذية بيانات السيرفر كقاعدة (`conflict_monitor_screen.dart:180-210`) — أي أن "merge" ليس دمجاً حقيقياً بل "السيرفر يفوز" باسم آخر.

### 🟡 P1-5 — synchronization في المقدمة فقط

`Timer.periodic(Duration(seconds: 30))` (`sync_provider.dart:205`). لا يوجد `WorkManager` ولا `background_fetch`. **إذا أُغلق التطبيق أو ذهبت Wave Pettigrew الهاتف، تتوقف المزامنة كلياً** — وهو ما يناقض الهدف المعلن لنظام "إنترنت ضعيف".

### 🟡 P2-1 — إشعار واحد فقط يستدعي المزامنة فوراً

`egg_production_screen.dart:186` فقط هو ما ينادي `syncAfterWrite()`. باقي الشاشات تنتظر حتى 30 ثانية — فيظهر للمستخدم مؤشر "قيد الانتظار" بلا سبب.

### 🟡 P2-2 — PIN من 4 أرقام = 10,000 احتمال أمام بيانات مالية

مُوثَّق في `SECURITY_AUDIT.md:337`. مع P0 أعلاه، هذا يخترق فعلياً.

### 🟡 P2-3 — `dispatch_requests` بلا قيود مرجعية

`schema_production.sql:536-545`: لا FK على `farm_id`/`customer_id`/`flock_id`، و`status` بلا `CHECK`. يخالف بقية المخطط.

### 🟡 P2-4 — `audit_log` معرَّف في المخطط وغير مكتوب

مرتبط بـ ACC-008 في التدقيق الحالي.

### 🟡 P2-5 — انحراف المخطط المحلي عن السيرفر

- `opening_balances` محلياً بلا `sync_status`/`version`/`deleted_at` رغم أنه في سجل المزامنة → `_reconcileServerDeleted` يتخطاه (`sync_repository_impl.dart:928-935`) لكن الـ DAO ما زال يضع في الطابور.
- `feed_received` محلياً بلا `sync_status`.
- `inventory_items` على السيرفر بلا `deleted_at`/`created_at` → دلالات التومبتون غير متماثلة مع 14 جدولاً آخر.
- `revenue.worker_id` نوعه `TEXT` على السيرفر بينما كل مراجع العامل الأخرى `UUID → users`.
- `egg_dispatch.worker_id` `NOT NULL` على السيرفر رغم أن تخريج المدير بلا عامل — يُحل بإدخال `''` في `_fillRequiredHousekeeping` (`sync_repository_impl.dart:1074-1092`).

### 🟡 P2-6 — اختباران فاشلان في `packages/data`

1. `repositories_impl_test.dart` — `PaymentRepositoryImpl.save`: متوقع `pending`، فعلي `synced`
2. `repositories_impl_test.dart` — `PaymentRepositoryImpl.getAll` عند انقطاع الشبكة: متوقع فارغ، فعلي فيه سجل من اختبار سابق (تسريب حالة)

كلاهما في مسار **القبض** — وهو المسار المالي الأكثر حساسية.

### 🟡 P2-7 — صفر اختبارات على التطبيقين

كل الاختبارات في `packages/`. لا يوجد أي `widget test` ولا اختبار تكامل على `desktop` أو `mobile`. الـ 28 و 19 شاشة **بلا أي اختبارات واجهة**.

### ⚪ P3-1 — رموز قديمة

- `app_routes.dart` (موبايل): 8 ثوابت، أغلبها لا وجود له في جدول المسارات.
- عزل مزدوج لـ `stock_adjustments` في `_onCreate` و `_onUpgrade<22`؛ `revenue` مكرر أيضاً → التثبيت الجديد والمسار المُرقّى يسلكان مسارين مختلفين لنفس الشكل.
- إصدارات 17، 18، 26، 28 من مخطط SQLite بلا كتل ترحيل (مطويّة).
- أخطاء كتابة عربية مشوّهة: `sync_provider.dart:19` (`نص آخر خطأсинcatch`)، `home_screen.dart:751` (`للcroft اليومي`).

### ⚪ P3-2 — `equipment_screen.dart` يعرض رقماً لا يعبّر عن الواقع

موثّق في الملف نفسه (`:8-12`): "الكمية المعروضة هي مخزون الصنف العالمي، ليس تخصيصه للقطيع" — فمجموع العمود قد يتجاوز المخزون الفعلي.

---

## 8. آلية المزامنة والعمل بدون إنترنت

### 8.1 المسار الكامل

```
[العامل يضغط حفظ]
   ↓
DAO يكتب في SQLite (سريع، دائماً ينجح)
   ↓
DAO ينادي enqueueChange() → صف في sync_queue (operation_id = UUIDv4)
   ↓
[كل 30 ثانية أو syncAfterWrite أو عودة الاتصال]
   ↓
SyncRepositoryImpl.getPendingChanges(limit:50)
   ├─ يحل farm_id: من payload → من السجل المحلي → لا أمان → تأجيل 30 دقيقة
   └─ يتخطّى الصفوف التي next_retry_at > الآن
   ↓
Edge Function sync_records (Deno)
   ├─ تحقق JWT (supabaseAdmin.auth.getUser)
   ├─ حدود: 200 سجل / 1MB
   ├─ تحقق farm_id: UUID صالح، إلزامي للـ INSERT
   └─ ينادي RPC بخادم عميل المستخدم (لا service_role) → RLS فعّال
   ↓
sync_records_batch(jsonb) في Postgres
   ├─ auth.uid() مطلوب
   ├─ user_has_farm_access(v_farm) ← من user_farms، لا من العميل
   ├─ sync_can_write(role, table) ← القائمة المسموحة بالدور
   ├─ قائمة أعمدة مسموحة، مُتقاطعة مع information_schema
   ├─ idempotency_log → تخطي العمليات المكررة
   └─ مقارنة previous_version مع version → conflict أم write
   ↓
[triggers] trg_populate_sync يكتب في sync_changes (تسلسل عالمي)
   ↓
=== الاتجاه العكسي ===
pull_remote_changes(p_farm_id, p_since_version)
   ↓
SyncRepositoryImpl.pullAndMerge
   ├─ INSERT/Missing → upsert، DELETE → حذف
   ├─ فشل صف → minFailedVersion، لا يتجاوز watermark
   └─ يحدّث sync_state.last_pulled_version إلى commitPoint
```

### 8.2 استراتيجية حل التعارض

**توفيق متفائل (OCC) قائم على إصدارات — وليس last-write-wins.** هذه نقطة قوة حقيقية:
- الخادم يقارن `previous_version` المُرسل من العميل مع `version` الحالي في الصف.
- عند الاختلاف → `status: 'conflict'` مع `server_version` و `client_version` في النتيجة.
- التعارضات تُحفظ في جدول `conflicts` المحلي (`client_data`, `server_data`, `status`, `suggested_action`).
- الحل يدوي: `client_wins` / `server_wins` / `ignore` — و`merge` غير منفّذ (P1-4).
- **السلوك عند فشل السحب مفصّل بعناية:** لا يتجاوز watermark إلا بعد نجاح كل الصفحات السابقة (`sync_repository_impl.dart:851-854`)، فلا يُفقد أي تغيير.
- **التومبتونات:** `sync_tombstone_after_delete` على 14 جدولاً.
- **المصالحة:** `_reconcileServerDeleted` يستدعي `sync_live_ids` كل 30 دقيقة، يحذف ما حُذف على السيرفر، ويتجاهل أي صف له عملية في الطابور.

### 8.3 مصفوفة القدرات Offline

| العملية | Offline | ملاحظات |
|---|---|---|
| إدخال إنتاج/نفوق/علف/دواء | ✔ كامل | 13 DAO تستدعي enqueueChange |
| تخريج (كمية) | ✔ كامل | بدون أي حقول مالية |
| بلاغ طارئ | ✔ صندوق صادر محلي | يُعاد إرساله عند عودة الاتصال |
| ملاحظات العامل | ✔ محلي 100% | لا تُزامن أبداً (بالتصميم) |
| طلب تخريج | ❌ **معطّل** | P1-1 |
| مصروفات/إيرادات/مخزون/دفعات | مدير فقط | عبر مباشر على السيرفر |
| الإشعارات | ❌ غير مخزّنة | `NotificationRepositoryImpl` يبتلع كل الأخطاء (`:37,45,53`) |

### 8.4 الموثوقية

- **Idempotency:** `idempotency_log` بمفتاح `operation_id` UNIQUE + تخطي في `00801:241-257`.
- **Backoff:** `_consecutiveFailures` مع تصاعد حتى 5 محاولات ثم فاصل حتى 30 دقيقة، ويُصفَّر عند النجاح (`sync_provider.dart:76-77,279-294`).
- **سجل الأخطاء:** `sync_queue.last_error` + `last_error_code` + `next_retry_at`، ورصد صحة المزامنة عبر `sync_health`.
- **حدّ المحاولات:** `_maxRetryAttempts = 5`.

---

## 9. نقاط القوة

1. **صفر أخطاء ترجمة في 43,451 سطر.** كل التحذيرات الـ 150 هي `info`/`warning` ( depreciations و const lint فقط). هذا نادر.

2. **الفصل بين التطبيقين مدروس ومنفَّذ على كل المستويات** — لا服从 UI فقط، بل في RPC المزامنة أيضاً. العامل حرفياً لا يستطيع تسجيل مخروف من التطبيق.

3. **معمارية المزامنة مصمَّمة بعناية عالية.** ثلاث قرارات نادرة في أنظمة إنترنت ضعيف:
   - لا تخمين لـ `farm_id` إطلاقاً — الـ INSERT يتطلبها، والـ UPDATE/DELETE يقرآنها من الصف الموجود على السيرفر.
   - Watermark لا يتجاوز أي فشل (`minFailedVersion`).
   - idempotency + تومبتون + مصالحة دورية.

4. **35 قاعدة تحقق على مستوى قاعدة البيانات** — لا يمكن-through-العميل كسر `broken + dirty > total` أو `paid > due` أو مخزون سالب.

5. **`packages/core` مستقل تماماً وقابل للاختبار** — 34 اختباراً منطقياً ناجحاً بلا أي محاكاة شبكة، بما فيها اختبارات تسمية واضحة بالعربية.

6. **نظام نسخ احتياطي متعدد المستويات** — `VACUUM INTO` للـ SQLite + تصدير CSV شامل + رفع سحابي + **تصدير تغييرات المزامنة المعلّقة** إلى `madjana_backups/pending_changes_<ts>.json` قبل المسح.

7. **معالجة farm_id تدل على خبرة عملية مؤلمة** — هذا خطأ حقيقي من النوع الذي يُكتشف في الإنتاج، وقد أُصلح عبر 3 هجرات متتالية، مع تعليقات واضحة تشرح "لماذا" وليس "ماذا".

8. **توثيق تدقيقي استثنائي.** خمسة تقارير تدقيق عميقة داخل المستودع نفسه (`SECURITY_AUDIT`, `ACCOUNTING_INTEGRITY_AUDIT`, `ERP_GAP_MATRIX`, `FULL_CODE_AUDIT`, `TEST_COVERAGE_GAPS`) — وهذا نادر جداً ويجعل النظام قابلاً للتحسين الذاتي.

9. **مصفوفة صلاحيات أعمدة على السيرفر** (`20260926000700:303-351`) — العامل يُمنع مثلاً من `feed_received.price_per_kg` و `egg_dispatch.payment_status` و `customer.is_global`، حتى لو تلاعب بالعميل.

10. **مقاومة حجب الأدوات:** استرجاع الجلسة offline، كاش المزرعة، قراءة الدفاتر من المحلي عند الانقطاع، وتجميد مزامنة ذكي عند فشل استرجاع `farm_id`.

---

## 10. الفجوات — ما ينقص التطبيق

### وظيفية
| الفجوة | الأثر |
|---|---|
| طلب التخريج لا يعمل (P1-1) | دورة موافقة معطّلة بالكامل |
| `medicines_catalog` لا يُزامن | تعديل الكتالوج على جهاز لا يصل لغيره |
| لا طباعة ولا PDF ولا مشاركة | التقارير على الشاشة فقط |
| لا مزامنة خلفية (P1-5) | لا مزامنة بعد إغلاق التطبيق |
| لا أدوار دقيقة (صندوق/محاسب/مالك) | إما مدير يرى كل شيء، أو عامل لا يرى شيئاً |
| لا قائمة دفعات (Chart of Accounts) ولا قيود مزدوجة | المحاسبة على ضغطة زر موحّدة لا على قيود |
| لا كشوف حساب وكشف أعمار للزبون | `total_debt` موجود لكن لا أعمار ولا كشف تفصيلي |
| لا تقييم مخزون (FIFO) | تكلفة البضاعة المباعة غير محسوبة |
| لا ذروة نقدية / خزينة | لا يمكن معرفة الرصيد النقدي الفعلي |

### تقنية
| الفجوة | الأثر |
|---|---|
| لا `widget test` على 47 شاشة | أي انحدار في الواجهة يمرّ صامتاً |
| لا اختبار RLS ل.factor العامل | P0 مرّ بلا إنذار |
| مسارات المخطط غير موثّقة الترتيب | P1-3 قد ينتكس عند أي إعادة تطبيق |
| لا CI/CD ظاهر | `.github` موجود لكن لم أفحصه |
| لا مراقبة/تنبيهات | لا نظام-watchdog لقاعدة البيانات |

---

## 11. التوصيات — مرتّبة حسب الأولوية

### 🔴 فوراً (خلال 24 ساعة)

**R1. إصلاح تصعيد الصلاحيات (P0).**
أضف migration جديدة **بعد** `00801` تعيد سياسات مدير-محدودة على الجداول المالية، معfarm-scoped في نفس الوقت:

```sql
-- مثال لـ payments (كرّر لـ expenses, revenue, opening_balances, inventory_items)
DROP POLICY IF EXISTS payments_read   ON public.payments;
DROP POLICY IF EXISTS payments_insert ON public.payments;
DROP POLICY IF EXISTS payments_update ON public.payments;
DROP POLICY IF EXISTS payments_delete ON public.payments;

CREATE POLICY payments_read ON public.payments FOR SELECT TO authenticated
  USING (public.user_manages_farm(farm_id));
CREATE POLICY payments_insert ON public.payments FOR INSERT TO authenticated
  WITH CHECK (public.user_manages_farm(farm_id));
CREATE POLICY payments_update ON public.payments FOR UPDATE TO authenticated
  USING (public.user_manages_farm(farm_id)) WITH CHECK (public.user_manages_farm(farm_id));
CREATE POLICY payments_delete ON public.payments FOR DELETE TO authenticated
  USING (public.user_manages_farm(farm_id));
```

**أو** — وهو الأنظف — عدّل `user_has_farm_access` لتقبل معامل صلاحية، أو أضف `user_writes_financials(farm_id)` واستخدمها للجداول المالية.

⚠️ **الأولوية المطلقة:** يجب التحقق أولاً مما إذا كانت هجرة 00800 مطبَّقة فعلاً على الإنتاج، بتشغيل:
```sql
SELECT tablename, policyname, cmd, qual
FROM pg_policies
WHERE schemaname='public' AND tablename IN ('payments','expenses','revenue');
```
إذا ظهر `payments_read` بشرط `user_has_farm_access` فالثغرة حيّة الآن.

**R2. اختبار حارس يمنع تكرار الثغرة** — اختبار SQL يق(assert) أن العامل يُرفض على الجداول المالية، يُضاف إلى `p0_isolation_and_sync_test.sql`. هذا هو الاختبار T3 المذكور في `TEST_COVERAGE_GAPS.md` ولم يُكتب.

**R3. تدوير سر قاعدة البيانات** الذي أُرسل في المحادثة، وتغيير مفتاح الاتصال. أي مفتاح مُعرَّض في محادثة يجب اعتباره مكشوفاً.

### 🟠 خلال أسبوع

**R4. إصلاح `dispatch_requests` (P1-1).** أضف `enqueueChange('dispatch_requests')` في `dispatch_request_dao.insert()`، واصنع `supabase_dispatch_request_datasource.dart`، **ووحّد أسماء الأعمدة** بين المحلي (`requested_cartons`) والسيرفر (`cartons`). أضف `notes`/`total_eggs`/`stock_eggs`/`decided_at`/`decided_by` إلى `DispatchRequestModel`.

**R5. توحيد وزن كيس العلف (P1-2).** قرّر قيمة واحدة واقفلها:
- إمّا 50 في كل مكان (موصى به —当前的 السيرفر default),
- أو اجعل `farms.feed_bag_weight_kg` مصدراً وحيداً، وأزل `AppConstants.kgPerBag`، وأضف trigger لـ `feed_received` كما هو موجود لـ `feed_consumption`.
- **ثم أعد حساب كل السجلات历史的** أو وثّق أن ما قبل التاريخ غير صحيح.

**R6. توثيق ترتيب الهجرات في ملف واحد** (`supabase/MIGRATION_ORDER.md`)，明确 init.sql ثم 00100→00801، مع تنبيه صريح بأن إعادة تطبيق `init.sql` بعد الـ migrations كاسرة. الأفضل: دمج `20260926*.sql` في `init.sql` ثم حذفها.

**R7. تنفيذ conflict `merge` حقيقياً** (P1-4) أو احذف الخيار من الواجهة بدل عرض خيار لا يعمل.

### 🟡 خلال شهر

**R8. مزامنة خلفية** (P1-5): أضف `workmanager` بمهمة دورية 15 دقيقة على Android + `syncNow()` في الإقلاع.

**R9. `syncAfterWrite()` في كل شاشات الإدخال** (P2-1) — هناك نموذج جاهز في `egg_production_screen.dart:186`.

**R10. تخزين الإشعارات محلياً** — `NotificationRepositoryImpl` يبتلع كل الأخطاء؛ اجعلها تكتب في جدول محلي ومزامنة مثل غيرها.

**R11. صفر drift بين المخطط المحلي والسيرفر** (P2-5) — أضف `sync_status`/`version`/`deleted_at` لـ `opening_balances` و `feed_received` محلياً؛ صحّح `revenue.worker_id` إلى `UUID`; أضف `created_at`/`deleted_at` لـ `inventory_items`.

**R12. اختبارات لمسار القبض** لإصلاح الفاشلين (P2-6) — ابدأ بإصلاح تسريب الحالة في `repositories_impl_test.dart`.

**R13. أدوار دقيقة** (فجوة وظيفية): إضافة `cashier` (قبض فقط) و `accountant` (تقارير فقط). `enums.dart` و `users.role` CHECK و `sync_can_write` جاهزة Locations للتوسعة — التكلفة منخفضة والأثر عالٍ.

### 🟢 تحسينات مستمرة

**R14. حذف `app_routes.dart`** الميتة، وتنظيف الرموز العربية المشوّهة، وإزالة التكرارات في `_onCreate`.

**R15. `widget test` على الشاشات الحرجة أولاً:** `dispatch_screen`, `payments_screen`, `egg_production_screen`, `login_screen`.

**R16. CI/CD**: `flutter analyze` (يجب أن يبقى صفر أخطاء) + `flutter test` + اختبارات SQL على كل push.

---

## 12. ملاحظات على جودة الكود والتنظيم

### التنظيم
- ✅ ممتاز: فصل packages واضح، تسمية موحّدة (`*_repository_impl`, `*_datasource`, `*_dao`, `*_provider`, `*_usecase`).
- ✅ ممتاز: الشاشات كلها بحجم معقول مع استثناءات مبرّرة (`dispatch_screen` 1,232 سطر و`settings_screen` 1,202 سطر — لكنهما منطقياً متجاوران لكل ما يخصهما).
- ✅ جيد: DAOs الشائعة في `datasources/local/daos`، المصادر البعيدة في `datasources/remote`.
- ⚠️ **`core/providers.dart` في الموبايل يمرر `expenseDao: null`** (`providers.dart:217`) — قبول صريح、软件 مقبول لكنه Indicator على أن الحزمة موصولة بم interfacial خاطئة.

### مؤشرات على نضج الفريق
- تعليقات تشرح **لماذا** لا **ماذا** — خصوصاً في المزامنة.
- التعارضات المعرفية موثّقة inline (وزن الكيس، قسمة 수익، denominators Mortal).
- تكرارات في `schema_production.sql`/`init.sql` أوقفت تلقائياً بكل `IF NOT EXISTS`.
- gitHub workflow موجود.

### مؤشرات تحتاج انتباه
- ⚠️ **ملفات الشاشات تكبر**: `dashboard_screen` 1,420 سطر، `analytics_hub_screen` 1,134، `feed_screen` 1,221، `dispatch_screen` 1,232. عند هذا الحجم تصبح الصيانة أصعب. يُنصح باستخراج widgets/panels مستقلة.
- ⚠️ **`system_admin_shell.dart` = 1,205 سطر** مع timer فارغ عمداً (`39-43`).
- ⚠️ `ensure_manager_policies` في `init.sql:3174` لا تزال موجودة كدالة مولِّدة لسياسات **غير مرتبطة بالمزرعة**. أي إعادة تشغيل لها تُرجع انحداراً أمنياً على 5 جداول.

---

## 13. خلاصة

النظام **أفضل من المتوسط بكثير** مما يدل عليه عدد ملفات المراجعة المتوازية التي احتاجها. البناء نظيف، الفصل البنيوي سليم، ومعمارية المزامنة هي الجزء الأثقل intellectually في المشروع وهي مصمَّمة باحترام حقيقي لبيئة إنترنت ضعيفة.

لكن هناك **ثغرة واحدة حرجة يجب إصلاحها اليوم**: آخر هجرة للبيانات (`20260926000800`) استبدلت سياسات مالية مشددة بسياسات أضعف، وأعادت للعامل حق قراءة وكتابة المدفوعات والمصروفات والإيرادات عبر الـ REST API — وهو ما يناقض كل ما يقوله التوثيق الداخلي عن النظام.

بعد إصلاحها، الأولوية الثانية هي `dispatch_requests` (وظيفة ميتة يظن المستخدم أنها تعمل)، ثم توحيد وزن كيس العلف (خطأ رقمي صامت)، ثم توثيق ترتيب الهجرات (خطأ انحدار مؤجّل).

**بعدها**، الأولوية وظيفية: أدوار دقيقة (cashier / accountant) porque تطبيقاً بثلاثة أدوار فقط لا يناسب مزرعة فيها محاسب.