# نظام إدارة المداجن (Poultry Farm Management)

نظام متكامل لإدارة مزارع الدواجن البياضة مع فاصل صارم بين صلاحيات **العامل** و**المدير**.

## البنية (Monorepo)

```
madjana/
├── packages/
│   ├── core/          # النماذج، الثوابت، واجهات المستودعات، Use Cases
│   ├── domain/        # إعادة تصدير core (فصل منطقي)
│   └── data/          # SQLite (Offline-first) + Supabase + المزامنة
├── apps/
│   ├── mobile/        # تطبيق الموبايل (Flutter) - للعامل
│   └── desktop/       # تطبيق سطح المكتب (Flutter/Windows) - للمدير
└── supabase/
    ├── migrations/    # SQL Schema كامل مع RLS و Triggers
    └── functions/     # Edge Functions (sync_records)
```

## المعمارية

- **Offline-first**: كل البيانات تُحفظ محلياً في SQLite ثم تُزامن مع Supabase عند توفر الاتصال.
- **فصل الصلاحيات**: العامل يُدخل بيانات تشغيلية فقط (إنتاج، نفوق، علف، تخريج) **بدون أسعار**.
  المدير فقط يرى البيانات المالية ويسجل الأسعار والقبض (عبر تطبيق سطح المكتب).
- **المزامنة**: طابور محلي (`sync_queue`) + دفعات (`Batch Upload`) مع **ضبط التزامن التفاؤلي
  (Optimistic Concurrency Control)** عبر حقل `version`: لا يمكن تحديث/حذف سجل تم تعديله على
  الخادم لاحقاً إلا بعد سحب أحدث إصدار — تستجيب الدفعة بحالة `conflict` مع إصدارَي الطرفين.

## الجداول الرئيسية

`farms`, `users`, `flocks`, `egg_production`, `mortality`, `feed_consumption`,
`feed_received`, `egg_dispatch`, `customers`, `payments`, `medications`,
`medicines_catalog`, `sync_queue`, `audit_log`.

> حساب `total_eggs` تلقائياً عبر Triggers، وتحديث `current_count` للقطعان عند النفوق،
> وتسجيل `audit_log` لكل عملية تعديل.

## التشغيل

### 1. المتطلبات
- Flutter 3.44+ (أو الأحدث)
- حساب Supabase (مجاني)

### 2. Supabase

**الطريقة الموصى بها (CLI):**
```bash
# تثبيت Supabase CLI إن لم يكن موجوداً
# npm install -g supabase

# ربط المشروع المحلي بـ Supabase
supabase link --project-ref <your-project-ref>

# تطبيق جميع الـ migrations تلقائياً
supabase db push
```

**الطريقة اليدوية (من محرر SQL في Dashboard):**
طبّق الملفات التالية بالترتيب من `supabase/migrations/`:
1. `20250101000000_initial_schema.sql`
2. `20260902_001_system_admin.sql`
3. `20260902_002_rls_system_admin.sql`
4. `20260902_003_mortality_atomicity.sql`
5. `20260904_004_inventory_payments_version.sql`
6. `20260904_005_sync_permissions_and_health.sql`

3. أنشئ الجداول المرجعية: `medicines_catalog` (كتالوج الأدوية).

4. أنشئ مستخدماً مديراً:
   ```sql
   INSERT INTO farms (name) VALUES ('مزرعة النموذج') RETURNING id;
   -- خذ الـ farm_id ثم:
   INSERT INTO users (id, name, phone, role, pin_hash, farm_id)
   VALUES (
     '<auth.user.id>',        -- من Authentication → Users
     'المدير', '07xxxxxxxx',
      'manager',
      '<bcrypt hash للرقم السري 4 أرقام عبر app_password_from_pin>',
      '<farm_id>'
    );
   ```
   > كلمة المرور المخزنة هي `'madjana$' + <الرقم السري 4 أرقام>`، وتُولَّد عبر الدالة
   > SQL `app_password_from_pin(p_pin)` التي تُشغَّل في migration، ثم يُحفظ ناتجها
   > لمطابقة عمود `encrypted_password` (bcrypt) الذي يتحقق منه GoTrue.

5. ارفع Edge Function:
   ```bash
   supabase functions deploy sync_records
   ```
6. عيّن المتغيرات: `SUPABASE_URL` و `SUPABASE_SERVICE_ROLE_KEY` (تلقائياً في dashboard).

### 3. ضبط المفاتيح
لا يُدمج أي مفتاح Supabase في الكود. تُمرَّر المفاتيح عبر أحد الطريقتين في كل من:
- `apps/mobile/lib/core/supabase_client.dart`
- `apps/desktop/lib/core/supabase_client.dart`

**الطريقة 1 — ملف `.env`** (موصى به محلياً):
```
SUPABASE_URL=https://YOUR_PROJECT.supabase.co
SUPABASE_ANON_KEY=YOUR_ANON_KEY
```

**الطريقة 2 — `--dart-define`** أثناء البناء/التشغيل:
```bash
flutter run --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
            --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY
```

### 4. تشغيل الموبايل
```bash
cd apps/mobile
flutter pub get
flutter run
```

### 5. تشغيل سطح المكتب
```bash
cd apps/desktop
flutter pub get
flutter run -d windows
```
> يتطلب Visual Studio مع "Desktop development with C++".

### 6. التحليل والاختبار
```bash
flutter analyze   # في كل حزمة/تطبيق
flutter test      # في packages/core (اختبارات حساب البيض)
```

## ملاحظات أمنية
- `payments` محمية بـ RLS: **المدير فقط**.
- العامل لا يصل أبداً لشاشة القبض ولا للأسعار (يُمنع حتى على مستوى التطبيق).
- PIN مشفّر بـ bcrypt (مع pepper `madjana$`) في `users.pin_hash`، ويطابق `encrypted_password` الذي يتحقق منه GoTrue.