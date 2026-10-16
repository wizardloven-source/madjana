# SYNC — إصدار المخطط: العقد بين الخادم والتطبيق (M9)

## لماذا هذا الملف

مزامنة Madjana Offline-first تبني على افتراض صامت: أن قاعدة البيانات البعيدة
والقاعدة المحلية "متفقتان" على شكل المخطط. افتراضٌ كان يتهاوى بصمت — تطبيق
مُحدَّث يتحدث إلى خادم لم تلحقه ترحيلاته بعد، أو تطبيق قديم يُرفع سجلات بصيغة
لا يفهمها خادم أحدث.

M9 ينهي الصمت: الخادم يُعلن إصدار **عقد المزامنة**، والعميل يقارن **عقده**
بإصدار الخادم قبل أي مزامنة.

## مقياسان مختلفان — لا تخلطهما

هناك رقمان في المنظومة، وخلطهما خطأ:

| الرقم | ماذا يعدّ؟ | أين | يُقارن بالخادم؟ |
|---|---|---|---|
| **عقد المزامنة** `kSyncContractVersion` | عصر العقد بين الخادم والعميل (شكل الجداول ودوال RPC التي تعتمد عليها المزامنة) | `packages/core/lib/src/constants/sync_contract.dart` | **نعم** — هذا ما تُقارنه البوابة |
| **ترحيل محلي** `_dbVersion` | عدّاد ترحيلات SQLite على الجهاز (فهارس، `sync_queue`، OCC، علامة مائية...) | `packages/data/.../local_database.dart` | **لا** — محلي بحت، لا يُرسل ولا يُقارن |

`_dbVersion` (حالياً 30) يرتفع مع كل تغيير في قاعدة الجهاز وليس له علاقة بعقد
الخادم. لذلك تراه أكبر بكثير من عقد المزامنة (حالياً 1) دون أي تعارض — هذا
طبيعي ومقصود.

## الأطراف الثلاثة

| الطرف | مكانه | القيمة |
|---|---|---|
| الخادم | `app_schema_version` — صف واحد `version` (الأعلى هو السائد) | يُقرأ عبر `current_schema_version()` RPC |
| العميل (عقد) | `kSyncContractVersion` (`packages/core/.../sync_contract.dart`) | `const int kSyncContractVersion = 1` |
| البوابة | مدخلا الإقلاع في `main.dart` (الموبايل وسطح المكتب) + مركز المزامنة (الموبايل) | `evaluateSyncContract()` → مسح/حظر/تحذير |
| العميل (محلي) | `local_schema_meta` → `schema_version` = `_dbVersion` | `LocalDatabase.getLocalSchemaVersion()` — **للعرض فقط، لا يدخل البوابة** |

## عقد RPC

```
current_schema_version() → integer
```

- `LANGUAGE sql`, `STABLE` (ثابتة داخل الجملة، لا كتابة)، `SECURITY DEFINER`
  مع `SET search_path = public` (حتى لا تُخطف الدالة بمسار بديل).
- ممنوحة `EXECUTE` لـ `authenticated` فقط. `anon` لا يقرأ الجدول ولا يستدعي
  الدالة — الرقم ليس مُعلَناً قبل تسجيل الدخول.
- RLS على الجدول: `app_schema_version_read FOR SELECT TO authenticated
  USING (true)` — استثناء مقصود (الرقم ليس بيانات مزرعة).
- الجدول **ليس** في `sync_table_registry`: عقدة بيانات، لا تُنسخ مطلقاً إلى
  الأجهزة.

## سلوك بوابة الإقلاع (القيم اللحظية)

المقارنة دائماً بين **`kSyncContractVersion`** وإصدار الخادم:

| الحالة | السلوك | رسالة |
|---|---|---|
| `contract == server` | **مسح** | — |
| `server > contract` | **حظر** (الخادم أحدث) | «إصدار الخادم (N) أحدث من التطبيق (M) — حدّث التطبيق» |
| `contract > server` | **تحذير فقط** (لا حظر) | يُطبع عبر `debugPrint` — التطبيق مبني لعقدٍ لم يُنشَر على الخادم بعد |
| فشل RPC / لا اتصال | **لا حظر** (Offline-first) | — |

قاعدة Offline-first غير قابلة للنقاش هنا: **فشل قراءة الإصدار لا يمنع فتح
التطبيق ولا المزامنة**. الحظر يحدث فقط على *اختلاف معلوم ومؤكَّد* هو
`server > contract`. أي استثناء داخل `current_schema_version()` يُسجَّل ويعود
`null` (لا حظر)، و`contract > server` يمرّ بتحذير لا بحظر (يُصحّح بنشر ترحيلات
الخادم).

في الموبايل: الشاشة التي تمنع الإقلاع تعيد استخدام مسار `_error` الحالي مع زر
«إعادة المحاولة». في سطح المكتب: `MadjanaDesktopApp(startupBlockMessage: …)`
تعرض شاشة حجب كاملة `_StartupBlockScreen` بدل الواجهة.

## رفع أرقام الإصدار (عندما تتغير المخططات لاحقاً)

**فرّق بين الحالتين:**

- **تغيير محلي بحت** (فهرس، عمود مساعد، جدول `sync_queue`، منطق OCC): ارفع
  `_dbVersion` فقط. عقد المزامنة **لا يتغير**، والباقي يعمل تلقائياً. لا تلمس
  `app_schema_version`.
- **تغيير يكسر العقد** (شكل جدول مشترك، دالة RPC، تنسيق حمولة المزامنة): ارفع
  **الرقمين معاً** — `app_schema_version` على الخادم و`kSyncContractVersion` في
  العميل — في نفس التغيير.

عند ترقية عقد تتطلب **مزامنة متوافقة**:

1. أضف صفاً في الترحيل نفسه (بعد `CREATE OR REPLACE` للكائنات الجديدة):

   ```sql
   INSERT INTO public.app_schema_version (version, min_client_version, notes)
   VALUES (2, 2, 'M10: description')
   ON CONFLICT (version) DO NOTHING;
   ```

2. في نفس الترحيل، ارفع `min_client_version` إذا كان التطبيق القديم يجب ألا
   يكتب بعدها (العميل-الأقدم-من-الحد يرى `server > contract` فيُحجب).

3. ارفع `kSyncContractVersion` في `sync_contract.dart` إلى نفس الرقم الجديد
   (2 في المثال).

4. أبقِ `p0_schema_version_test.sql` محدَّثاً (يُتوقع `version = 2`، تراجع
   يزيل الصف الجديد، إعادة تطبيق تعيده).

**القاعدة الذهبية:** `version` يزيد واحدة كل مرة، و`applied_at` يكتبه
Postgres نفسه (`now()`)، ولا يُعدَّل صف قديم في مكانه — الإصدارات سجلٌّ
زمني للترحيلات، لا خانة أحداث. وبالمثل: `kSyncContractVersion` يتبع
`app_schema_version` النشط، و`_dbVersion` يتبع ترحيلات الجهاز — لا يُوائم بين
الاثنين لأن مقياسيهما مختلفان.

## أين يُعرض

- مركز المزامنة (الموبايل — `sync_center_screen.dart`): بطاقة «عقد المزامنة
  (M9)» تعرض **ثلاثة** أرقام منفصلة: `عقد العميل` و`عقد الخادم` و`ترحيل محلي`.
  الحالة من `evaluateSyncContract()`: خضراء عند التطابق، حمراء عند
  `server > contract` (حظر)، صفراء عند `contract > server` (تحذير)، رمادية عند
  تعذّر قراءة الخادم.
- بوابتا الإقلاع: كما في القسم أعلاه.

## كود البوابة

- `packages/core/lib/src/constants/sync_contract.dart` —
  `kSyncContractVersion` + `SyncContractState` + `evaluateSyncContract()`.
- `apps/mobile/lib/main.dart` — `_checkSchemaVersionGate()` داخل `_boot()`.
- `apps/desktop/lib/main.dart` — `_schemaVersionBlock()` قبل `runApp`.
- `packages/data/lib/src/datasources/remote/supabase_api.dart` —
  `fetchServerSchemaVersion()` (واجهة + محوّل `SupabaseClientApiAdapter`).
- `packages/data/lib/src/datasources/local/local_database.dart` —
  `getLocalSchemaVersion()` (للعرض المحلي فقط).

## قواعد الالتقاط في المزامنة (M10)

مسار المزامنة المسموع — لا silent catch (التفاصيل الكاملة في
`docs/ERROR_HANDLING.md`):

- **نهي مطلق عن `catch (_)`** في `sync_repository_impl.dart` وكل ملفات
  `packages/data` و `packages/core` وواجهات التطبيقات.
- مسارات الرفع/السحب ترمي أو تعيد الرمي عند فشل الشبكة الحقيقي، ومسارات
  fallback (الكاش المحلي) تَعمد إلى القيمة المحلية لكنها تطبع السبب عبر
  `debugPrint('madjana: …')` — لا يُبتلع خطأٌ بلا أثر.
- `sync_records_batch` بلا جلسة على الخادم يرمي `AUTHORIZATION_DENIED`
  (وليس نجاحاً فارغاً)؛ يثبت ذلك `supabase/tests/p0_catch_test.sql`
  (مجموعة **4o** في `run_all.py`).
- ملفات الحارس: `packages/data/test/static_catch_rules_test.dart` +
  `p0_catch_test.sql` + أسطر `madjana:` المطبوعة التي ينفّذها `flutter test`.

## التراجع (M9)

`20261003000901_rollback_app_schema_version.sql` يحذف الدالة والجدول. بعدها
لا وجود لـ `current_schema_version()`؛ عميل M9 يتعامل مع الفشل كـ«offline»
(لا حظر)، فلا ينكسر التطبيق — لكن العقد يختفي حتى يُعاد تطبيق الـ forward.

## الاختبارات

- `p0_schema_version_test.sql` (suite **4n** في `run_all.py`): وجود الكائنات،
  الصف `(1, 1, 'initial')`، `current_schema_version() = 1`، سياسة القراءة
  المفتوحة، حرمان `anon`، انعدام الصف في `sync_table_registry`، إعادة تطبيق
  idempotent، التراجع، وإعادة التطبيق.
- `packages/data` — `fake_supabase_api.dart` ينفذ `fetchServerSchemaVersion()`
  (يُبلغ `serverSchemaVersion`، يرمي عند `failReads`) وبقاياه في `calls`.
- `packages/core/test/sync_contract_test.dart` — 4 حالات البوابة
  (`match`/`serverAhead`/`clientAhead`/`unknown`) + تأكيد انطلاق العقد من 1
  واستقلاله عن `_dbVersion`.