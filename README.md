# نظام إدارة المداجن — Madjana Poultry Farm Management

نظام متكامل لإدارة مزارع الدواجن البياضة — offline-first، متعدد المزارع، مع فاصل صارم بين الصلاحيات.

---

## نظرة عامة

| المكوّن | التفاصيل |
|---------|----------|
| **المنصة** | Android (Mobile) + Windows (Desktop) |
| **التقنية** | Flutter + Dart + Riverpod |
| **قاعدة البيانات** | SQLite (محلي) + Supabase PostgreSQL (سحابي) |
| **المزامنة** | Offline-first مع queue + OCC + exponential backoff |
| **الأمان** | RLS على جميع الجداول + فصل صلاحيات worker/manager/system_admin |
| **الدعم** | Arabic RTL بالكامل + Dark Mode |

---

## المعمارية

```
madjana/
├── packages/
│   ├── core/          # النماذج (20)، الثوابت، Enums، Use Cases (7)، واجهات المستودعات (12)، خدمات التحليلات (1126 سطر)
│   ├── domain/        # إعادة تصدير core
│   └── data/          # SQLite/DAOs (16)، Remote Datasources (16)، Repositories (15)، محرك المزامنة (934 سطر)
├── apps/
│   ├── mobile/        # تطبيق الموبايل — 20 ميزة
│   └── desktop/       # تطبيق سطح المكتب — 27 شاشة
└── supabase/
    ├── migrations/    # 8 ملفات migration
    └── functions/     # sync_records Edge Function
```

### التدفق المعماري

```
المستخدم ← Screen (Presentation) ← Provider (Riverpod)
    ← Repository Interface (core)
    ← Repository Impl (data)
    ├── Local DAO (SQLite) ← enqueueChange() ← sync_queue
    └── Remote Datasource (Supabase) ← Edge Function / RPC
```

---

## الميزات الأساسية

### 1. إدارة الإنتاج اليومية
| الميزة | Mobile | Desktop |
|--------|--------|---------|
| تسجيل إنتاج البيض (كراتين/أطباق/ Fortress) | ✅ | ✅ |
| البيض السليم / المكسور / المتسخ | ✅ | ✅ |
| حساب total_eggs تلقائياً عبر Trigger | ✅ | ✅ |
| نسخ إنتاج الأمس | ✅ | ✅ |
| تسجيل النفوق مع الأسباب (6 أسباب) | ✅ | ✅ |
| تحذير النفوق المرتفع (>1%) | ✅ | ✅ |
| استلام الأعلاف (كيس/كغ/טון) | ✅ | ✅ |
| استهلاك الأعلاف مع عرض المخزون الحالي | ✅ | ✅ |
| تخريج البيض (بيع) مع التحقق من المخزون | ✅ | ✅ |
| طلب موافقة.Manager على التخريج الزائد | ✅ | ✅ |

### 2. إدارة القطعان
| الميزة | الحالة |
|--------|--------|
| إنشاء/تعديل/حذف قطيع | ✅ |
| تتبع: السلالة، تاريخ البداية، العدد الابتدائي | ✅ |
| العنابر (sections) | ✅ |
| حالات القطيع: نشط / مغلق | ✅ |
| حساب العمر تلقائياً (أيام/أسابيع/أشهر) | ✅ |
| حساب current_count عبر triggers (نفوق + حركات) | ✅ |
| حركات القطيع (إضافة/بيع/نقل/إعدام) — جدول `flock_movements` | ✅ DB + Trigger |

### 3. إدارة العملاء والمدفوعات
| الميزة | Mobile | Desktop |
|--------|--------|---------|
| إدارة العملاء (إضافة/تعديل/حذف) | ✅ | ✅ |
| التخريج (dispatch) مع تتبع الزبون | ✅ | ✅ |
| حالات الدفع: مدفوع / جزئي / معلق | ✅ | ✅ |
| تسجيل المدفوعات (USD/Lira) | ✅ | ✅ |
| سعر الصرف | ✅ | ✅ |
| إجمالي الذمم المدينة | ✅ | ✅ |

### 4. الأدوية والصحة
| الميزة | Mobile | Desktop |
|--------|--------|---------|
| كتالوج الأدوية (9 أدوية افتراضية) | ✅ | ✅ |
| تسجيل إعطاء الدواء (نوع/جرعة/طريقة/أيام علاج) | ✅ | ✅ |
| فترة سحب الدواء (Withdrawal Period) | ✅ | ✅ |
| **منع بيع البيض أثناء فترة السحب** | ✅ | ✅ |
| تحذير بعد تسجيل الدواء | ✅ | ✅ |

### 5. المخزون
| الميزة | Mobile | Desktop |
|--------|--------|---------|
| إدارة الأصناف | ❌ | ✅ |
| حركات الإدخال/الإخراج | ✅ | ✅ |
| تنبيهات المخزون المنخفض/الحرج | ✅ | ✅ |
| حماية من المخزون السالب (Dart + DB Trigger) | ✅ | ✅ |

### 6. التقارير والتحليلات
| الميزة | Mobile | Desktop |
|--------|--------|---------|
| ملخص اليوم (بيض/نفوق/علف) | ✅ | ✅ |
| تقارير 7 أيام مع رسم بياني | ✅ | ❌ |
| لوحة تحكم تنفيذية | ✅ (ملخص) | ✅ (8 تبويبات) |
| تحليلات الإنتاج/Nfوق/العلف | ✅ | ✅ |
| أداء القطعان (FlockPerformance) | ✅ | ✅ |
| تحليل 360 للعملاء | ✅ | ✅ |
| ذكاء الموردين (من feed_received) | ✅ | ✅ |
| تكلفة البيضة (تقديرية) | ✅ | ✅ |
| ربحية كل قطيع | ✅ | ✅ |
| تصدير CSV | ✅ | ❌ |

### 7. نظام المزامنة (Production-Grade)
| الميزة | الحالة |
|--------|--------|
| Offline-first — كتابة محلية أولاً | ✅ |
| `sync_queue` مع `operation_id` | ✅ |
| Batch Upload عبر Edge Function | ✅ |
| Incremental Pull مع `pull_remote_changes` RPC | ✅ |
| Per-farm watermark (لا عالمي) | ✅ |
| Optimistic Concurrency Control (OCC) | ✅ |
| Exponential backoff (5s → 30min) | ✅ |
| Conflict Detection + Resolution | ✅ |
| Anti-resurrection (منع إعادة سجلات محذوفة) | ✅ |
| Tombstone propagation للحذف الناعم | ✅ |
| Idempotency عبر `idempotency_log` | ✅ |
| Reconciliation مع السيرفر | ✅ |
| مزامنة متعددة الأجهزة | ✅ |
| سجل المزامنة (sync_history) | ✅ |
| شاشة مراقبة التعارضات (ConflictMonitorScreen) | ✅ |

### 8. الأمان والصلاحيات
| الميزة | الحالة |
|--------|--------|
| 3 أدوار: worker / manager / system_admin | ✅ |
| RLS على جميع 27 جدول | ✅ |
| farm_id isolation على جميع الجداول التشغيلية | ✅ |
| farm_id isolation على الجداول المالية (payments/expenses) | ✅ |
| Worker لا يصل للبيانات المالية | ✅ |
| حماية تغيير الدور عبر triggers | ✅ |
| PIN مع pepper + bcrypt | ✅ |
| Rate limiting للدخول | ✅ |
| Account lockout بعد 5 محاولات | ✅ |
| `sync_can_write` / `sync_can_read` للتحكم في المزامنة | ✅ |

---

## الجداول

### جداول البيانات (27 جدول)

| الجدول | الغرض | Sync |
|--------|--------|------|
| `farms` | المزارع | ❌ |
| `users` | المستخدمون | ❌ |
| `user_farms` | ربط المستخدمين بالمزارع | ❌ |
| `flocks` | القطعان | ✅ |
| `egg_production` | إنتاج البيض | ✅ |
| `mortality` | النفوق | ✅ |
| `feed_consumption` | استهلاك الأعلاف | ✅ |
| `feed_received` | استلام الأعلاف | ✅ |
| `egg_dispatch` | تخريج البيض | ✅ |
| `customers` | العملاء | ✅ |
| `payments` | المدفوعات | ✅ |
| `expenses` | المصاريف | ✅ |
| `medications` | الأدوية | ✅ |
| `medicines_catalog` | كتالوج الأدوية | ❌ |
| `inventory_items` | أصناف المخزون | ✅ |
| `inventory_transactions` | حركات المخزون | ✅ |
| `opening_balances` | الأرصدة الافتتاحية | ✅ |
| `dispatch_requests` | طلبات التخريج | ✅ |
| `flock_movements` | حركات القطيع | ✅ |
| `sync_changes` | سجل التغييرات | - |
| `sync_checkpoint` | علامة مائية لكل مزرعة | - |
| `sync_conflicts` | التعارضات | - |
| `idempotency_log` | منع التكرار | - |
| `audit_log` | سجل التدقيق | - |
| `login_throttle` | تحديد محاولات الدخول | - |
| `app_settings` | إعدادات التطبيق | ❌ |
| `app_notifications` | الإشعارات | ✅ |

---

## المتطلبات

- **Flutter:** 3.44+
- **Supabase:** حساب (مجاني)
- **Windows Desktop:** Visual Studio مع "Desktop development with C++"

---

## التشغيل

### 1. قاعدة البيانات (Supabase)

> **ملف واحد لكل الحالات: `supabase/init.sql`**
> ملف موحّد يضم `UNIFIED_schema.sql` + جميع ملفات `UPGRADE_*.sql`
> (بأحدث تعريف لكل كيان)، وهو **idempotent** وآمن على البيانات.

| الحالة | الملف الذي يوضَع في SQL Editor | النتيجة |
|--------|-------------------------------|---------|
| **قاعدة جديدة** (تطبيق جديد بلا بيانات) | `supabase/init.sql` | يُنشئ كل شيء من الصفر: الجداول، الدوال، المشغلات، سياسات RLS، الفهارس — وتصبح القاعدة جاهزة فوراً |
| **قاعدة قائمة فيها بيانات** (تحديث لأحدث نسخة) | `supabase/init.sql` | تحديث فقط: `CREATE TABLE/INDEX ... IF NOT EXISTS`، `ADD COLUMN IF NOT EXISTS`، `CREATE OR REPLACE FUNCTION`، إعادة السياسات والمشغلات بأحدث تعريف — **لا حذف بيانات، لا DROP TABLE** |

خطوات التنفيذ في **Supabase Dashboard → SQL Editor**:
1. افتح `supabase/init.sql` وانسخ محتواه كاملاً.
2. الصقه في الـ SQL Editor واضغط **Run**.
3. آمن لإعادة التشغيل أكثر من مرة (`run twice = same state`).

> ملاحظة: مجلد `supabase/migrations/` يبقى كمرجع تاريخي للتطوير؛
> لا داعي لتشغيل ملفاته يدوياً عند استخدام `init.sql`.

ثم ارفع Edge Function:
```bash
supabase functions deploy sync_records
```

### 2. ضبط المفاتيح
أنشئ ملف `.env` في كل من `apps/mobile/` و `apps/desktop/`:
```
SUPABASE_URL=https://YOUR_PROJECT.supabase.co
SUPABASE_ANON_KEY=YOUR_ANON_KEY
```

### 3. تشغيل الموبايل
```bash
cd apps/mobile
flutter pub get
flutter run
```

### 4. تشغيل سطح المكتب
```bash
cd apps/desktop
flutter pub get
flutter run -d windows
```

### 5. البناء
```bash
# APK
cd apps/mobile && flutter build apk --debug

# Windows EXE
cd apps/desktop && flutter build windows --debug
```

### 6. التحليل والاختبار
```bash
# في كل حزمة
dart analyze

# اختبارات core
cd packages/core && dart test

# اختبارات data
cd packages/data && dart test
```

---

## هيكل الصلاحيات

| الصلاحية | Worker | Manager | System Admin |
|----------|--------|---------|-------------|
| تسجيل إنتاج البيض | ✅ | ✅ | ✅ |
| تسجيل النفوق | ✅ | ✅ | ✅ |
| تسجيل استهلاك/استلام العلف | ✅ | ✅ | ✅ |
| تخريج البيض | ✅ (مع موافقة) | ✅ | ✅ |
| تسجيل الأدوية | ✅ | ✅ | ✅ |
| رؤية الأسعار | ❌ | ✅ | ✅ |
| تسجيل المدفوعات | ❌ | ✅ | ✅ |
| تسجيل المصاريف | ❌ | ✅ | ✅ |
| إدارة المخزون | ❌ | ✅ | ✅ |
| إدارة العمال | ❌ | ❌ | ✅ |
| إنشاء مزرعة | ❌ | ❌ | ✅ |
| التقارير المالية | ❌ | ✅ | ✅ |
| التحليلات | ✅ (غير مالي) | ✅ | ✅ |

---

## Offline / Sync

```
[Mobile/Desktop] ──── SQLite (محلي) ──── sync_queue
       │                                       │
       │                          enqueueChange() مع operation_id
       │                                       │
       ▼                                       ▼
  UI تفاعلية                          [SyncNotifier] (كل 30 ثانية)
                                              │
                          ┌────────────────────┼────────────────────┐
                          ▼                    ▼                    ▼
                    uploadBatch()        pullAndMerge()       cleanup()
                    (Edge Function)      (RPC)               (古い records)
                          │                    │
                          ▼                    ▼
                   [Supabase PostgreSQL]  [sync_changes table]
                          │
              ┌───────────┼───────────┐
              ▼           ▼           ▼
        sync_records_batch   pull_remote_changes   sync_live_ids
        (idempotent + OCC)   (incremental pull)    (anti-resurrection)
```

### Conflict Resolution
- **OCC:** `previous_version` في كل operation — السيرفر يرفض إذا كان `version > previous_version`
- **Server wins (as default):** بيانات السيرفر تطغى
- **Client wins:** إعادة إرسال بيانات العميل
- **Ignore:** تجاهل التعارض
- **Merge (محدود):** استخدام بيانات السيرفر كأساس

---

## ملاحظات تقنية

- **20 ملف model** في `packages/core` مع serialization + validation + computed properties
- **7 use cases** مع قواعد عمل حقيقية (لا hardcoded)
- **1126 سطر** في `phase1_analytics.dart` — خدمات تحليلات شاملة
- **16 DAO** في `packages/data` — كلها real implementations (لا stubs)
- **16 remote datasource** — Supabase CRUD كامل
- **15 repository impl** — offline-first مع sync queue
- **934 سطر** في `SyncRepositoryImpl` — محرك مزامنة production-grade
- **45 database function** في PostgreSQL
- **27 trigger** في قاعدة البيانات
- **8 ملف migration** — كلها additive (لا DROP TABLE)
- **174 اختبار وحدة** — passing

---

## الترخيص

proprietary — Madjana Poultry Farm
