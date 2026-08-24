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
- **المزامنة**: طابور محلي (`sync_queue`) + دفعات (`Batch Upload`) + حل تعارض
  "الأحدث يفوز" (Last Write Wins).

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
1. أنشئ مشروع Supabase.
2. نفّذ ملف `supabase/migrations/001_initial_schema.sql` من محرر SQL.
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
     '<sha256 للرقم السري 4 أرقام>',
     '<farm_id>'
   );
   ```
5. ارفع Edge Function:
   ```bash
   supabase functions deploy sync_records
   ```
6. عيّن المتغيرات: `SUPABASE_URL` و `SUPABASE_SERVICE_ROLE_KEY` (تلقائياً في dashboard).

### 3. ضبط المفاتيح
في كل من:
- `apps/mobile/lib/core/supabase_client.dart`
- `apps/desktop/lib/core/supabase_client.dart`

استبدل:
```dart
static const String supabaseUrl = 'https://YOUR_PROJECT.supabase.co';
static const String supabaseAnonKey = 'YOUR_ANON_KEY';
```
بمفاتيح مشروعك الفعلي.

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
- PIN مشفّر بـ SHA-256 في `users.pin_hash`.