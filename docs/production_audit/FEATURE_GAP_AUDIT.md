# Madjana Poultry Farm — Feature Gap Audit

**تاريخ التدقيق:** 2026-09-15
**الإصدار:** 1.0
**النطاق:** Mobile + Desktop + Core + Data + Database + Sync + Security

---

## ملخص الإحصائيات

| الفئة | العدد |
|-------|-------|
| الميزات المفحوصة | 16 مجال |
| مكتملة (COMPLETE) | 5 مجالات |
| جزئية (PARTIAL) | 7 مجالات |
| واجهة فقط (UI_ONLY) | 2 مجالات |
| غير موجودة (NOT_IMPLEMENTED) | 2 مجالات |
| مكسورة (BROKEN) | 0 |
| خطوط قاعدة البيانات العاطلة | 0 |

---

## المجال الأول: إدارة المزارع

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| إنشاء مزرعة | ✅ | ✅ | ✅ RPC | ❌ | ✅ | system_admin only | ❌ | PARTIAL | P1 |
| تعديل المزرعة | ✅ | ✅ | ✅ | ❌ | ✅ | manager+ | ❌ | PARTIAL | P2 |
| حذف المزرعة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| تعدد المزارع | ✅ | ✅ | ✅ user_farms | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| ربط المستخدم بأكثر من مزرعة | ✅ | ✅ | ✅ | ❌ | ✅ | system_admin | ❌ | COMPLETE | - |
| صلاحيات الوصول لكل مزرعة | ✅ | ✅ | ✅ RLS | - | ✅ | ✅ | ❌ | COMPLETE | - |
| إدارة العنابر (sections) | ✅ | ✅ | ✅ JSONB | ❌ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| نقل المستخدم بين المزارع | ✅ | ✅ | ✅ RPC | ❌ | ✅ | system_admin | ❌ | COMPLETE | - |
| إحصائيات كل مزرعة | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| أرشفة المزرعة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| إعدادات المزرعة | ✅ | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | COMPLETE | - |
| الوحدات المستخدمة | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P2 |
| العملة | ✅ | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | COMPLETE | - |
| المنطقة الزمنية | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| قوالب التشغيل | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |

**ملاحظات:**
- إنشاء المزرعة متاح عبر RPC `create_farm_with_manager` و `bootstrap_create_farm_and_manager`
- تعديل المزرعة محدود — `updateFarm` في `FarmRepositoryImpl` هو remote-only (fire-and-forget) بدون local DB
- إدارة العنابر (`sections_count`) موجودة كرقم في `FlockModel` لكن لا يوجد CRUD منفصل للعنابر — الإدخال يتم عبر `section_no` في سجلات الإنتاج

---

## المجال الثاني: إدارة القطعان Flocks

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| إنشاء القطيع | ✅ | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | COMPLETE | - |
| مصدر القطيع | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |
| تاريخ الاستلام | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| عدد الطيور الابتدائي | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| السلالة | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| العمر | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| العنبر | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P2 |
| الحالة الحالية | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| قطيع نامٍ | ❌ | ❌ | ✅ status | - | - | - | - | DATABASE_ONLY | P1 |
| قطيع إنتاج | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| قطيع متراجع | ❌ | ❌ | ✅ status | - | - | - | - | DATABASE_ONLY | P1 |
| قطيع مغلق (endFlock) | ✅ | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | COMPLETE | - |
| بيع أو التخلص | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| نقل القطيع بين العنابر | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| نقل القطيع بين المزارع | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| إضافة طيور | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| طرح الطيور | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| احتساب العدد الحالي تلقائيًا | ✅ via mortality trigger | ✅ via mortality trigger | ✅ trigger | ✅ | ✅ | ✅ | ❌ | PARTIAL | P0 |

**المعادلة المطلوبة:**
```
العدد النهائي = الابتدائي + الإضافات - النفوق - النقل - البيع - الإعدام
```
- **الحالي:** `current_count` يتم تعديله فقط عبر `mortality` trigger (نفوق فقط)
- **الناقص:** لا يوجد: إضافة طيور، بيع، نقل، إعدام — لا يوجد trigger أو UI لهذه العمليات
- **الخطر:** `current_count` قد يصبح غير دقيق إذا تم بيع أو نقل طيور دون تسجيل

---

## المجال الثالث: إنتاج البيض

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| تسجيل الإنتاج اليومي | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| إنتاج كل قطيع | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| إنتاج كل عنبر | ✅ via section_no | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P2 |
| إنتاج كل مزرعة | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| البيض السليم | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| البيض المكسور | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| البيض المتسخ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| البيض المستبعد | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |
| إجمالي الإنتاج | ✅ | ✅ | ✅ trigger | ✅ | ✅ | ✅ | ✅ | COMPLETE | - |
| نسبة الإنتاج | ✅ via FarmAnalytics | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| متوسط الإنتاج | ✅ via phase1_analytics | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| مقارنة المتوقع بالفعلي | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |
| تقارير يومية/أسبوعية/شهرية | ✅ mobile reports | ✅ desktop reports | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| تعديل السجل مع Audit Log | ❌ | ❌ | ✅ audit_log table | ✅ | ✅ | ❌ | ❌ | DATABASE_ONLY | P1 |
| منع التكرار لنفس القطيع والتاريخ | ❌ | ❌ | ✅ getByDate check | ✅ | ✅ | ✅ | ❌ | PARTIAL | P0 |
| إغلاق اليوم التشغيلي | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |

**ملاحظات:**
- `EggProductionModel.getByDate(farmId, flockId, date)` يوجد في DAO لكن لا يوجد فحص تكرار في UseCase أو الشاشة
- منع التكرار يعتمد على `getRecordByDate` في repository لكن لا يوجد UI feedback إذا كان السجل موجودًا (يتم overwrite)

---

## المجال الرابع: النفوق

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| تسجيل النفوق | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | COMPLETE | - |
| أسباب النفوق | ✅ enum | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| نفوق طبيعي | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| نفوق مرضي | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| إعدام | ✅ via reason enum | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| إجمالي النفوق | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| نسبة النفوق | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | COMPLETE | - |
| مقارنة بالحدود الطبيعية | ✅ via MortalityKpi | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| تنبيه عند ارتفاع النفوق | ✅ via UseCase | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | COMPLETE | - |
| منع تجاوز عدد الطيور | ✅ via UseCase | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | COMPLETE | - |
| ربط بالقطيع والعنبر والمزرعة | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| تقارير وتحليلات | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |

**التقييم:** هذا المجال **مكتمل** تقريبًا. جميع الميزات الأساسية موجودة.

---

## المجال الخامس: الأعلاف

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| أنواع الأعلاف | ✅ enum FeedType | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| مخزون الأعلاف | ✅ via计算 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| استلام الأعلاف | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| استهلاك الأعلاف | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| تحويل الأعلاف بين المخازن | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| استهلاك كل قطيع | ✅ via flock_id | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| استهلاك كل عنبر | ❌ | ❌ | ✅ section_no | ✅ | ✅ | ✅ | ❌ | DATABASE_ONLY | P2 |
| استهلاك كل مزرعة | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| تكلفة الكيلو | ✅ via feed_received.price_per_kg | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | COMPLETE | - |
| متوسط الاستهلاك اليومي | ✅ via phase1_analytics | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| الاستهلاك المتوقع مقابل الفعلي | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |
| Feed Conversion Ratio | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P1 |
| حد إعادة الطلب | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |
| تنبيهات انخفاض المخزون | ✅ via StockAlert | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| منع المخزون السالب | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P0 |
| تتبع Batch/Lot | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |
| تاريخ الصلاحية | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |
| FEFO | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P3 |

**ملاحظات:**
- `getCurrentFeedStock()` يحسب من `received - consumption` فقط
- لا يوجد حماية لمنع المخزون السالب في `saveConsumptionLocal`
- لا يوجد Batch/Lot tracking أو FEFO

---

## المجال السادس: الصحة البيطرية

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| جدول اللقاحات | ✅ medicines_catalog | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| خطة لقاحات لكل قطيع | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| تسجيل إعطاء اللقاح | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| اسم اللقاح | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| الجرعة | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| التاريخ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| الطبيب أو المسؤول | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |
| رقم التشغيلة | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P3 |
| تاريخ الصلاحية للدواء | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |
| العلاجات | ✅ via medications | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| الأدوية | ✅ via medicines_catalog | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| الجرعات | ✅ dosage field | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| مدة العلاج | ✅ treatment_days | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| فترة سحب الدواء | ✅ withdrawal_days | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| منع بيع البيض أثناء السحب | ⚠️ warning only | ⚠️ warning only | ❌ | - | - | ❌ | - | BROKEN | P0 |
| تنبيهات اللقاحات القادمة | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |
| سجل صحي كامل للقطيع | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| تقارير الأمراض | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |
| ربط الدواء بالمخزون | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P1 |
| خصم الدواء من المخزون | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P1 |
| منع صرف دواء منتهي الصلاحية | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |

**الخطر الرئيسي:** فترة سحب الدواء تظهر كتحذير فقط في الواجهة — لا يوجد حماية في قاعدة البيانات أو في `DispatchRepository` لمنع بيع البيض أثناء فترة السحب. يجب تنفيذ هذا في `SaveDispatchUseCase` أو في trigger.

---

## المجال السابع: العمال والمهام

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| إدارة العمال | ❌ | ✅ users_screen | ✅ RPC | ❌ | ✅ | system_admin | ❌ | DESKTOP_ONLY | P1 |
| ربط العامل بمزرعة | ✅ | ✅ | ✅ user_farms | ❌ | ✅ | system_admin | ❌ | COMPLETE | - |
| الحضور والانصراف | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| الورديات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| المهام اليومية | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| المهام المتكررة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| توزيع المهام | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| حالة المهمة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| إثبات إنجاز المهمة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| المهام المتأخرة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| سجل نشاط العامل | ❌ | ❌ | ✅ audit_log | - | ✅ | ✅ | ❌ | DATABASE_ONLY | P2 |
| صلاحيات العامل | ✅ via UserRole | ✅ | ✅ RLS | - | ✅ | ✅ | ❌ | COMPLETE | - |
| منع تعديل بيانات خارج النطاق | ✅ via RLS | ✅ | ✅ RLS | - | ✅ | ✅ | ❌ | COMPLETE | - |

---

## المجال الثامن: البيئة والتشغيل

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| درجة الحرارة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| الرطوبة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| التهوية | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| الإضاءة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| استهلاك المياه | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| ضغط المياه | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| حالة المعدات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| تسجيل القراءات اليومية | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| الحدود الطبيعية | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| تنبيهات الخروج عن الحدود | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| سجل القراءات لكل عنبر وقطيع | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| تقارير التغيرات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| دعم العمل Offline | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |

**التقييم:** هذا المجال **غير موجود بالكامل** — يتطلب جدولاً جديداً `environmental_readings` + مزامنة + واجهة.

---

## المجال التاسع: المشتريات والموردون

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| إدارة الموردين | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| بيانات الاتصال | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| الأصناف التي يوردها المورد | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| تاريخ الأسعار | ❌ | ❌ | ✅ price_per_kg | ✅ | ✅ | manager+ | ❌ | DATABASE_ONLY | P2 |
| طلب شراء | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| أمر شراء | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| استلام بضاعة | ✅ feed_received | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| فاتورة شراء | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| دفعة للمورد | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| مرتجع شراء | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| حساب المورد | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| كشف حساب المورد | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| الذمم الدائنة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| حالات الموافقة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| ربط الاستلام بالمخزون | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| منع تسجيل فاتورة دون استلام | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| دعم العملات | ❌ | ❌ | ✅ | ✅ | ✅ | manager+ | ❌ | DATABASE_ONLY | P2 |

**الحالة:** `feed_received` يسجل الاستلام فقط. لا يوجد جدول `suppliers`، لا يوجد جدول `purchase_orders`، لا يوجد حسابات موردين.

---

## المجال العاشر: المبيعات والعملاء

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| إدارة العملاء | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| أوامر البيع | ✅ dispatch_requests | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| تجهيز الطلب | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| Dispatch | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| فاتورة البيع | ✅ via dispatch+payment | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| قبض الدفعة | ✅ payments | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | COMPLETE | - |
| مرتجع المبيعات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| كشف حساب العميل | ❌ | ❌ | ✅ total_debt | ✅ | ✅ | manager+ | ❌ | DATABASE_ONLY | P1 |
| الذمم المدينة | ✅ via payments | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | PARTIAL | P1 |
| حد ائتماني | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| منع تجاوز الحد الائتماني | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| ربط المبيعات بالمخزون | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| ربط المبيعات بإنتاج البيض | ✅ via dispatch flock_id | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| تتبع مصدر البيض حسب القطيع | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| حالات الفاتورة | ✅ PaymentStatus enum | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| سجل التعديلات | ❌ | ❌ | ✅ audit_log | ✅ | ✅ | ❌ | ❌ | DATABASE_ONLY | P1 |

**ملاحظات:**
- لا يوجد جدول `suppliers` منفصل — اسم المورد يُدخل كنص في `feed_received`
- لا يوجد `purchase_orders` أو `purchase_invoices`
- `dispatch_requests` لا يُزامَن مع السحابة (محلية فقط)
- `total_debt` في `customers` يتم تحديثه عبر trigger لا يزال غير واضح إذا كان مكتملاً

---

## المجال الحادي عشر: المخزون

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| الأصناف | ❌ (لا يوجد UI مباشر) | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | DESKTOP_ONLY | P1 |
| التصنيفات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| المستودعات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| أرصدة المخزون | ✅ via StockAlert | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | PARTIAL | P1 |
| حركات الإدخال والإخراج | ✅ via adjustStock | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | PARTIAL | P1 |
| التحويل بين المستودعات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| التسويات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| الجرد | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| Batch/Lot | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| تاريخ الصلاحية | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| FEFO | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| منع المخزون السالب | ✅ via adjustStock | ✅ | ❌ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P0 |
| تكلفة المخزون | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| سجل حركة الصنف | ✅ via inventory_transactions | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| ربط بالمشتريات والمبيعات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| تنبيهات النقص | ✅ via StockAlert | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| تنبيهات انتهاء الصلاحية | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |

**ملاحظات:**
- `InventoryRepositoryImpl.adjustStock()` يوجد حماية من المخزون السالب في كود Dart لكن لا يوجد trigger في قاعدة البيانات
- لا يوجد `inventory_categories` أو `inventory_warehouses` tables

---

## المجال الثاني عشر: المصاريف والمالية

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| المصاريف | ✅ | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | COMPLETE | - |
| تصنيف المصاريف | ✅ ExpenseCategory enum | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | COMPLETE | - |
| المصروف حسب المزرعة | ✅ | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | COMPLETE | - |
| المصروف حسب العنبر | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| المصروف حسب القطيع | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| المصروف حسب الفترة | ✅ via fromDate/toDate | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | COMPLETE | - |
| المورد أو المستفيد | ✅ via description field | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | PARTIAL | P2 |
| المرفقات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| الموافقات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| الصندوق | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| التدفقات النقدية | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| الذمم المدينة | ✅ via payments | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | PARTIAL | P1 |
| الذمم الدائنة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| الربحية | ✅ via phase1_analytics | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| تكلفة البيضة | ✅ via CostPerEgg | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| تكلفة القطيع | ✅ via FlockProfitability | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| تكلفة العلف | ✅ via feed_received | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | COMPLETE | - |
| تكلفة الدواء | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| تكلفة العمال | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| تكلفة التشغيل | ❌ | ❌ | ✅ | ✅ | ✅ | manager+ | ❌ | DATABASE_ONLY | P1 |
| تقرير الربح والخسارة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| تقرير التدفق النقدي | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |

**ملاحظات:**
- `CostPerEgg` و `FlockProfitability` في `phase1_analytics.dart` حسابات تقريبية (cost based on feed + expenses / eggs produced)
- لا يوجد `cost_of_medications` أو `cost_of_labor` في الحسابات
- لا يوجد `cash_flow` table أو `cash_registers` table
- `profit_loss_report` و `cash_flow_report` غير موجودة

---

## المجال الثالث عشر: الأصول والصيانة

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| المعدات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| المولدات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| البطاريات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| خطوط المياه | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| خطوط العلف | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| المركبات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| الأصول الثابتة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| تاريخ الشراء | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| القيمة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| الضمان | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| الصيانة الوقائية | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| الصيانة الطارئة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| قطع الغيار | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| تكلفة الصيانة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| سجل الأعطال | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |
| تنبيهات الصيانة القادمة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P3 |

**التقييم:** هذا المجال **غير موجود بالكامل** — ميزات مستقبلية.

---

## المجال الرابع عشر: التقارير والإدارة

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| لوحة تحكم تنفيذية | ✅ home summary | ✅ dashboard | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| مؤشرات كل مزرعة | ✅ via analytics | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| مؤشرات كل عنبر | ❌ | ❌ | ❌ | - | - | - | - | NOT_IMPLEMENTED | P2 |
| مؤشرات كل قطيع | ✅ via FlockPerformance | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| تقارير الإنتاج | ✅ reports screen | ✅ analytics tabs | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| تقارير النفوق | ✅ via reports | ✅ analytics | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| تقارير الأعلاف | ✅ via reports | ✅ analytics | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| تقارير الصحة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| تقارير المخزون | ✅ via StockAlert | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| تقارير المبيعات | ✅ via reports | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| تقارير المشتريات | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| تقارير العملاء والموردين | ✅ via phase1 analytics | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| تقارير المصاريف | ✅ via reports | ✅ | ✅ | ✅ | ✅ | manager+ | ❌ | PARTIAL | P1 |
| تقارير الربحية | ✅ via phase1 analytics | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| تقارير المقارنة بين المزارع | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| تصدير PDF | ✅ CSV export only | ❌ | - | - | - | - | ❌ | BROKEN | P1 |
| تصدير Excel أو CSV | ✅ CSV mobile | ❌ | - | ✅ | - | ✅ | ❌ | MOBILE_ONLY | P1 |
| الطباعة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| الفلاتر الزمنية | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| الفلاتر حسب المزرعة والعنبر والقطيع | ✅ partial | ✅ partial | ✅ | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| التقارير Offline | ✅ via local DB | ✅ via local DB | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |

**ملاحظات:**
- Mobile لا يوجد تصدير PDF — يوجد CSV فقط
- Desktop لا يوجد تصدير على الإطلاق
- لا يوجد طباعة
- لا يوجد مقارنة بين المزارع

---

## المجال الخامس عشر: النظام والصلاحيات

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| system_admin | ✅ | ✅ | ✅ RLS | - | ✅ | ✅ | ❌ | COMPLETE | - |
| manager | ✅ | ✅ | ✅ RLS | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| supervisor | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| worker | ✅ | ✅ | ✅ RLS | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| مصفوفة صلاحيات واضحة | ✅ via UserRole enum | ✅ | ✅ | - | ✅ | ✅ | ❌ | PARTIAL | P1 |
| صلاحيات القراءة | ✅ via RLS | ✅ | ✅ | - | ✅ | ✅ | ❌ | COMPLETE | - |
| صلاحيات الإنشاء | ✅ via RLS | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| صلاحيات التعديل | ✅ via RLS | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| صلاحيات الحذف | ✅ via RLS | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| صلاحيات الموافقة | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| صلاحيات التصدير | ❌ | ❌ | ❌ | - | - | ❌ | - | NOT_IMPLEMENTED | P2 |
| صلاحيات إدارة المستخدمين | ❌ mobile | ✅ desktop users | ✅ RPC | - | ✅ | system_admin | ❌ | DESKTOP_ONLY | P1 |
| صلاحيات متعددة المزارع | ✅ | ✅ | ✅ user_farms | - | ✅ | system_admin | ❌ | COMPLETE | - |
| منع تجاوز الصلاحيات (API) | ✅ via RLS + sync_can_write | ✅ | ✅ | - | ✅ | ✅ | ❌ | COMPLETE | - |
| منع تجاوز الصلاحيات (SQLite) | ❌ | ❌ | - | ❌ | - | ❌ | - | NOT_IMPLEMENTED | P0 |
| التحقق من RLS | ❌ | ❌ | ✅ | - | ✅ | ✅ | ❌ | DATABASE_ONLY | P1 |
| تسجيل العمليات الحساسة | ❌ | ❌ | ✅ audit_log | - | ✅ | ✅ | ❌ | DATABASE_ONLY | P1 |

**الخطر الرئيسي:** `audit_log` table موجود في قاعدة البيانات لكن لا يوجد Dart code يكتب إليه. لا يوجد `AuditLogRepository` أو `AuditLogDao`. فقط triggers في قاعدة البيانات تكتب البيانات (role change triggers).

---

## المجال السادس عشر: Offline وSync

| الميزة | Mobile | Desktop | Database | Offline | Sync | Permissions | Tests | الحالة | الأولوية |
|--------|--------|---------|----------|---------|------|-------------|-------|--------|----------|
| إنشاء البيانات دون إنترنت | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| تعديل البيانات دون إنترنت | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| حذف البيانات دون إنترنت | ✅ | ✅ | ✅ tombstone | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| Queue | ✅ sync_queue | ✅ sync_queue | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| Retry | ✅ exponential backoff | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| Idempotency | ✅ via operation_id | ✅ | ✅ idempotency_log | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| منع التكرار | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| Conflict Resolution | ✅ | ✅ | ✅ sync_conflicts | ✅ | ✅ | ✅ | ❌ | PARTIAL | P0 |
| Optimistic Concurrency | ✅ | ✅ | ✅ previous_version | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| server_version | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| previous_version | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| مزامنة Mobile إلى Supabase | ✅ | - | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| مزامنة Desktop إلى Supabase | - | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| سحب البيانات من Supabase | ✅ | ✅ | ✅ pull_remote_changes | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| مزامنة متعددة الأجهزة | ✅ | ✅ | ✅ per-device | ✅ | ✅ | ✅ | ❌ | PARTIAL | P1 |
| عرض أخطاء المزامنة | ✅ | ✅ | ✅ sync_history | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| إعادة المحاولة | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| عدم فقدان البيانات | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| عدم تجاوز farm_id | ✅ | ✅ | ✅ RLS | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| عدم قبول هوية من payload | ✅ | ✅ | ✅ server validates | ✅ | ✅ | ✅ | ❌ | COMPLETE | - |
| اختبار انقطاع الإنترنت | ❌ | ❌ | - | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| اختبار تكرار الطلب | ❌ | ❌ | - | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |
| اختبار تعارض تعديلين | ❌ | ❌ | - | - | - | ❌ | - | NOT_IMPLEMENTED | P1 |

**ملاحظات:**
- ConflictMonitorScreen في Desktop هو **بلاça** — يوجد كود TODO placeholder فقط
- `conflict_usecases.dart` — `merge` resolution ي扔 `throw UnimplementedError('Merge resolution not implemented yet')`
- لا يوجد اختبارات وحدة للمزامنة أو التعارض

---

## ملخص الأولويات

### P0 — مشاكل تؤثر على سلامة البيانات أو الأمان

| # | المشكلة | المجال | التفاصيل |
|---|---------|--------|----------|
| P0-01 | RLS payments/expenses لا يوجد farm_id | المالية | أي manager يمكنه قراءة/تعديل بيانات أي مزرعة |
| P0-02 | منع المخزون السالب فقط في Dart | المخزون | لا يوجد trigger في DB — ممكن تجاوز عبر SQL مباشر |
| P0-03 | فترة السحب لا تمنع البيع | الصحة | يظهر تحذير فقط — لا يوجد حماية في قاعدة البيانات |
| P0-04 | ConflictMonitorScreen بلاça | المزامنة | لا يوجد UI لحل التعارضات |
| P0-05 | Merge conflict resolution غير موجود | المزامنة | `throw UnimplementedError` في ConflictUseCases |
| P0-06 | DispatchRequestDao لا يُزامَن | المبيعات | `dispatch_requests` محلية فقط — لا تظهر في الأجهزة الأخرى |
| P0-07 | `current_count` لا يحسب الإضافات/البيع/النقل | القطعان | المعادلة ناقصة — فقط النفوق يُخصم |

### P1 — ميزات ضرورية لتشغيل مزرعة احترافية

| # | الميزة | المجال |
|---|--------|--------|
| P1-01 | إدارة الموردين + حساباتهم | المشتريات |
| P1-02 | فواتير الشراء + الذمم الدائنة | المشتريات |
| P1-03 | كشف حساب العميل | المبيعات |
| P1-04 | ربط الاستلام بالمخزون | المشتريات/المخزون |
| P1-05 | سجل صحي كامل للقطيع | الصحة |
| P1-06 | خصم الدواء من المخزون | الصحة/المخزون |
| P1-07 | ربط الدواء بالمخزون | الصحة/المخزون |
| P1-08 | إدارة العمال (Mobile) | العمال |
| P1-09 | تقرير الربح والخسارة | المالية |
| P1-10 | تقرير التدفق النقدي | المالية |
| P1-11 | تصدير PDF | التقارير |
| P1-12 | تصدير Excel (Desktop) | التقارير |
| P1-13 | التحقق من RLS في Dart | الأمان |
| P1-14 | تسجيل Audit Log في Dart | الأمان |
| P1-15 | اختبارات المزامنة | الاختبارات |
| P1-16 | اختبارات الصلاحيات | الاختبارات |
| P1-17 | فلاتر المزرعة/العنبر/القطيع الكاملة | التقارير |
| P1-18 | تقارير الصحة | التقارير |
| P1-19 | تقارير المشتريات | التقارير |
| P1-20 | صلاحيات إدارة المستخدمين (Mobile) | الصلاحيات |
| P1-21 | مصفوفة صلاحيات واضحة | الصلاحيات |
| P1-22 | تعديل/حذف سجل مع Audit Log | التدقيق |
| P1-23 | منع التكرار في UseCase | البيانات |
| P1-24 | بيع/إضافة/طرح الطيور | القطعان |
| P1-25 | إغلاق اليوم التشغيلي | الإنتاج |
| P1-26 | Feed Conversion Ratio | الأعلاف |
| P1-27 | الأصناف في Mobile | المخزون |
| P1-28 | مقارنة بين المزارع | التقارير |

### P2 — ميزات مهمة لتحسين الإدارة

| # | الميزة | المجال |
|---|--------|--------|
| P2-01 | تكلفة الدواء والعمالة | المالية |
| P2-02 | حسابات المورد التفصيلية | المشتريات |
| P2-03 | حد ائتماني للعملاء | المبيعات |
| P2-04 | مرتجع المبيعات | المبيعات |
| P2-05 | مرتجع الشراء | المشتريات |
| P2-06 | الجرد + التصنيفات | المخزون |
| P2-07 | Batch/Lot + تاريخ الصلاحية | المخزون/الأعلاف |
| P2-08 | خطة لقاحات لكل قطيع | الصحة |
| P2-09 | الحضور والانصراف | العمال |
| P2-10 | المهام اليومية | العمال |
| P2-11 | البيئة والتشغيل | البيئة |
| P2-12 | الموافقات | المالية |
| P2-13 | الصندوق | المالية |
| P2-14 | الطباعة | التقارير |
| P2-15 | أرشفة المزرعة | المزارع |
| P2-16 | إعدادات الوحدات | المزارع |

### P3 — ميزات مستقبلية

| # | الميزة | المجال |
|---|--------|--------|
| P3-01 | الأصول والصيانة | الأصول |
| P3-02 | التحويل بين المستودعات | المخزون |
| P3-03 | FEFO | المخزون |
| P3-04 | قوالب التشغيل | المزارع |
| P3-05 | المنطقة الزمنية | المزارع |
| P3-06 | المهام المتكررة | العمال |
| P3-07 | التهوية والإضاءة | البيئة |
| P3-08 | المرفقات | المالية |
