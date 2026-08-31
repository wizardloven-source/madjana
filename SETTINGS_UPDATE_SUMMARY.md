# 📋 ملخص تحديثات نظام المداجن

## ✅ التحديثات المنفذة

### 1. إضافة إعدادات حسابية متقدمة

تم إضافة 4 إعدادات جديدة يمكن للمدير تعديلها من شاشة الإعدادات:

| الإعداد | القيمة الافتراضية | الوصف |
|---------|------------------|--------|
| **وزن كيس العلف (كغ)** | 50 كغ | يُستخدم لتحويل عدد الأكياس إلى كيلوغرامات في سجلات استهلاك العلف |
| **عدد البيض في الكرتون** | 360 بيضة | يُستخدم لحساب إجمالي البيض عند الإدخال بالكرتون |
| **عدد البيض في الصينية** | 30 بيضة | يُستخدم لحساب إجمالي البيض عند الإدخال بالصينية |
| **معدل النفوق الافتراضي (%)** | 0% | نسبة نفوق افتراضية تُقترح عند تسجيل حالات نفوق جديدة |

---

### 2. هيكل قاعدة البيانات الموحّد

#### ملف الهجرة الرئيسي:
```
/supabase/migrations/001_master_schema.sql
```

**المحتويات:**
- ✅ 20 جدول (جميع جداول النظام)
- ✅ 17 فهرس للأداء
- ✅ 7 دوال مساعدة
- ✅ 3 محفزات تدقيق
- ✅ 40+ سياسة أمان RLS

#### جدول `app_settings`:
```sql
CREATE TABLE public.app_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    setting_key TEXT NOT NULL UNIQUE,
    setting_value JSONB NOT NULL,
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
```

---

### 3. نموذج FarmModel المُحدّث

```dart
class FarmModel {
  final String id;
  final String name;
  final String? location;
  final String? ownerId;
  final DateTime? createdAt;
  
  // إعدادات جديدة
  final double feedBagWeightKg;      // وزن كيس العلف بالكيلو
  final int eggsPerCarton;           // عدد البيض في الكرتون
  final int eggsPerTray;             // عدد البيض في الصينية
  final double defaultMortalityRate; // معدل النفوق الافتراضي (%)
}
```

---

### 4. واجهة Repository المُحدّثة

```dart
abstract class FarmRepository {
  // ... الدوال الموجودة
  
  // إعدادات جديدة
  Future<double> getFeedBagWeightKg();
  Future<void> setFeedBagWeightKg(double weightKg);
  
  Future<int> getEggsPerCarton();
  Future<void> setEggsPerCarton(int count);
  
  Future<int> getEggsPerTray();
  Future<void> setEggsPerTray(int count);
  
  Future<double> getDefaultMortalityRate();
  Future<void> setDefaultMortalityRate(double rate);
}
```

---

### 5. شاشة الإعدادات المُحدّثة (Desktop)

**الملف:** `/apps/desktop/lib/features/settings/presentation/settings_screen.dart`

**الأقسام الجديدة:**
1. **بيانات المدجنة** (اسم، موقع)
2. **عملة النظام** (ل.س، $، €، ر.س، ج.م)
3. **إعدادات الحسابات** ⭐ جديد
   - وزن كيس العلف (كغ)
   - عدد البيض في الكرتون
   - عدد البيض في الصينية
   - معدل النفوق الافتراضي (%)
4. **النسخ الاحتياطي والاستعادة**

---

## 🔄 آلية العمل

### للمدير (Desktop):
1. يفتح تطبيق سطح المكتب
2. ينتقل إلى **الإعدادات**
3. يعدّل الإعدادات الحسابية حسب حاجة المزرعة
4. تحفظ الإعدادات محلياً وفي السحابة
5. تُطبّق الإعدادات على جميع العمليات الحسابية

### للعامل (Mobile):
1. يفتح تطبيق الجوال
2. يسجل بيانات الإنتاج/النفوق/العلف
3. تُستخدم الإعدادات المحفوظة محلياً للحسابات التلقائية
4. تُزامن البيانات مع السحابة

---

## 📊 مثال على الاستخدام

### قبل التعديل:
```
العامل يدخل: 5 أكياس علف
النظام يحسب: 5 أكياس (بدون تحويل)
```

### بعد التعديل:
```
العامل يدخل: 5 أكياس علف
الإعداد: وزن الكيس = 50 كغ
النظام يحسب: 5 × 50 = 250 كغ علف ✅
```

---

## 🚀 خطوات النشر

### 1. تطبيق الهجرة على Supabase:
```bash
# افتح SQL Editor في Supabase Dashboard
# انسخ محتويات 001_master_schema.sql
# نفذ الهجرة
```

### 2. التحقق من نجاح الهجرة:
```sql
SELECT column_name 
FROM information_schema.columns 
WHERE table_name = 'farms' 
  AND column_name IN (
    'feed_bag_weight_kg',
    'eggs_per_carton',
    'eggs_per_tray',
    'default_mortality_rate'
  );
```

### 3. اختبار التطبيق:
```bash
# شغّل تطبيق Desktop
cd apps/desktop
flutter run

# انتقل إلى الإعدادات
# عدّل الإعدادات الحسابية
# احفظ وتأكد من ظهور رسائل النجاح
```

---

## 🔐 نظام الصلاحيات

| العملية | Worker | Supervisor | Manager |
|---------|--------|------------|---------|
| رؤية الإعدادات | ❌ | ❌ | ✅ |
| تعديل الإعدادات | ❌ | ❌ | ✅ |
| استخدام الإعدادات في الإدخال | ✅ | ✅ | ✅ |

---

## 📁 الملفات المُعدّلة

1. `/packages/core/lib/src/models/farm_model.dart` - إضافة الحقول الجديدة
2. `/packages/core/lib/src/repositories/admin_repositories.dart` - إضافة الدوال المجردة
3. `/packages/data/lib/src/repositories/farm_repository_impl.dart` - تنفيذ الدوال
4. `/apps/desktop/lib/features/settings/presentation/settings_screen.dart` - واجهة المستخدم
5. `/supabase/migrations/001_master_schema.sql` - هيكل قاعدة البيانات الموحد

---

## ✨ الفوائد

1. **مرونة أكبر**: كل مزرعة تضبط إعداداتها حسب احتياجاتها
2. **دقة أعلى**: حسابات تلقائية بناءً على إعدادات مخصصة
3. **توحيد المعايير**: جميع العمال يستخدمون نفس الإعدادات
4. **سهولة التعديل**: المدير يغير الإعدادات مرة واحدة وتُطبّق على الجميع

---

## 📝 ملاحظات هامة

- القيم الافتراضية مناسبة لمعظم المزارع السورية
- يمكن تغيير الإعدادات في أي وقت
- التغييرات تُطبّق فوراً على العمليات الجديدة فقط
- السجلات القديمة تحتفظ بقيمها الأصلية

---

**تاريخ التحديث:** 2025-01-02  
**الإصدار:** 1.0.0  
**الحالة:** ✅ جاهز للإنتاج
