# REPORTS — وضع التقرير (فترة / تراكمي) — M11

> M11. يوثّق كيفية حساب التقارير والمؤشرات في وضعين:
> **«فترة»** (نشاط النطاق المحدد فقط) و**«تراكمي»** (النطاق + الأرصدة
> الافتتاحية كاملة).

---

## 1. الفكرة

الأرصدة الافتتاحية (`opening_balances`) سجلات قديمة لقطعان دخلت النظام بعد
بدء عملها فعلياً: بيض منتج، نفوق، علف، مدفوعات، إيرادات — قبل أي تسجيل. مشكلتها
أنها **بلا تاريخ يومي داخل النطاقات**؛ «أنشئت» قبل النظام.

- في **«فترة»**: الرصيد لا ينتمي لنطاقٍ محدد، فأنسب قرار هو **صفره** — تعرض
  شاشة «اليوم»/«آخر 7 أيام»/الشهر نشاط الفترة الحقيقي دون تلويث برصيد قديم.
- في **«تراكمي»**: الرصيد تاريخٌ حقيقي يجب ألا يختفي — **يُجمع كاملاً** بلا أي
  ترشيح بتاريخ الإنشاء (حُذف `range.contains(b.createdAt)`).

قبل M11 كان الترشيح بـ `createdAt` يقرر وحده: نطاقات ضيقة تحذف الرصيد
القديم، ونطاقات واسعة تُدخله. أصبح القرار للمستخدم عبر المبدّل.

---

## 2. مصدر الحقيقة

```dart
// packages/core/lib/src/services/phase1_analytics.dart
enum ReportMode { period, cumulative }

class DateRange {
  final ReportMode mode; // الافتراضي: period؛ DateRange.all() → cumulative
}
```

قاعدة الاستخدام: **داخل `phase1_analytics.dart` لا يقرأ أي حاسبة الوضع إلا من
`range.mode`** — المستدعي يمرر القيمة الرصيدية (full) والحاسبة تصفّرها في
«فترة»، فلا يحدث انحراف بين مصدر وآخر.

---

## 3. السلوك لكل مؤشر

| الحاسبة | في «فترة» (period) | في «تراكمي» (cumulative) |
|---|---|---|
| `ProductionKpi.calculate` | `openingBalanceEggs = 0` — `totalEggs` = البيض داخل النطاق فقط | `openingBalanceEggs` كاملة — `totalEggs` = النطاق + الرصيد |
| `MortalityKpi.calculate` | `openingBalanceMortality = 0`؛ `deathsByReason` **لا يحتوي** `'opening_balance'` | النفوق الكامل + `deathsByReason['opening_balance']` |
| `FlockPerformance.calculate` | يفوّض إلى الحاسبتين أعلاه (بنفس `range.mode`) | نفسه + الرصيد عبر `openingBalance` |
| `productionRate` | البيض اليومي ÷ (الطيور × الأيام) — لا يتجاوز 100% | نفسه دائماً (الرصيد لا يدخل النسبة) — لا يتجاوز 100% |

`FlockPerformance` أُزيلت منه **تكلفة التقدير** (`علف × سعر البيضة` — كانت
مضللة). منذ **M12** تُحسب التكلفة الحقيقية عبر `FlockCostCalculator` وتظهر
في `costBreakdown` (علف + دواء + مصروف مباشر + تسويات مخزون، بلا مصروف
مزرعة) — `docs/ACCOUNTING_RULES.md` §6.

---

## 4. أين تسري الحسابات

**Providers (الحسابات الآلية):**
- `apps/desktop/lib/core/analytics_providers.dart` — `productionKpiProvider`
  و`mortalityKpiProvider`: يصفران الافتتاح عند `period` ويجمعانه كاملاً عند
  `cumulative` (حُذف ترشيح `range.contains(b.createdAt)`).
- `apps/mobile/lib/features/analytics/providers/analytics_providers.dart` —
  نفس القاعدة (نفس السلوك على الموبايل).

**الشاشات:**
- `period_filter.dart` — عنصر `ReportModeToggle` (SegmentedButton «فترة /
  تراكمي») ومعاملات `mode`/`onModeChanged` داخل `QuickPeriodBar` (اختيارية،
  تظهر عند تمريرها فقط).
- `apps/desktop/lib/features/reports/presentation/reports_screen.dart` —
  مبدّل + تصفير/جمع أرصدة التجهيز في المجاميع المالية والإنتاج والنفوق والعلف.
- `apps/desktop/lib/features/analytics/presentation/analytics_hub_screen.dart` —
  مبدّل في شريط النطاقات يمرر الوضع داخل `DateRange` إلى كل التبويبات؛ نطاق
  «السابق» المقارن يرث وضع النطاق الحالي.
- `apps/mobile/lib/features/reports/presentation/reports_screen.dart` —
  مبدّل + إضافة الأرصدة الافتتاحية في «تراكمي» لليوم والأسبوع وتصدير CSV.

---

## 5. الاختبارات

`packages/core/test/report_mode_test.dart` — 20 تأكيداً:
- «فترة»: أرصدة الافتتاح تصفَّر (بيض ونفوق).
- «تراكمي»: الأرصدة تدخل كاملة، ولا تتأثر بتاريخ إنشائها (2020 خارج النطاق).
- `deathsByReason` لا يحتوي `'opening_balance'` في «فترة»، ويحتويه في «تراكمي».
- `productionRate ≤ 100%` حتى مع رصيد افتتاحي.
- `FlockPerformance`: أُزيلت تكلفة `علف × سعر البيضة`، والرصيد يعمل في «تراكمي».
- `DateRange.all()` تراكمي والبقية فترة.

---

## 6. التوسعة

أي حاسبة تقرأ بيانات عالمية في المستقبل:
1. أضف معامل الرصيد، وطبق القاعدة قبل الجمع:
   ```dart
   final opening = range.mode == ReportMode.cumulative ? openingBalance : 0;
   ```
2. لا تقرر بترشيح التواريخ — الوضع وحده يقرر (لكي يبقى سلوك الشاشتين موحداً).
3. أضف سطراً في جدول §3 وفّداءً في `docs/SCHEMA_REFERENCE.md` §8.