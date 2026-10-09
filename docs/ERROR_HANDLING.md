# ERROR_HANDLING — قاعدة «لا silent catch» (M10)

## ما الذي تنصّه القاعدة

أي `catch` في `packages/data/lib` و `packages/core/lib` يجب أن يكون **مسموعاً**،
أي يُنهي الفشل بإحدى ثلاث طرائق فقط:

| الطريقة | متى تُستخدم | أمثلة في الكود |
|---|---|---|
| **إعادة الرمي** | مسار لا يملك ردّاً أفضل — يترك الخطأ يصعد إلى المتصل | `rethrow` / `throw …` |
| **`SyncFailure` / خطأ موصوف** | فشل عملية بعيدة يُغلَّف بكود مستقر | `throw SyncFailure('AUTH', …)` |
| **`debugPrint` صريح** | مسار fallback (Offline-first) يختار البيانات المحلية عمداً — لا يصمت عن السبب | `debugPrint('madjana: … $e')` |

الفئة المقيّدة `on X catch (…)` معفاة: التقاط نوعٍ بعينه **بحدّ ذاته**
إعلانٌ عن النيّة، ولا يلزمه طبع. (لا يزال يُفضَّل الطبع حيث توجد معلومات.)

في واجهات التطبيقات (`apps/*/lib`) المسموح أوسع: `catch (e)` + `debugPrint` عادةً،
لكن **`catch (_)` الصامت محظور في كل مكان** — الواجهات أيضاً.

## لماذا لا يكفي الـ analyzer

اختُبر واقعياً على هذا المشروع:

- `avoid_catches_without_on_clauses: error` — **معروف لكنه خامل**: لا يُبلغ عن
  `catch (_) {}` الصامت في هذا الإصدار من المحلّل.
- `avoid_catch_without_on_clauses: error` (الاسم المركّب) — **غير معروف**:
  يحوّل `flutter analyze` إلى خطأ `unrecognized_error_code`.

لذلك صُمّم **الإنفاذ الحقيقي** كاختبار ثابت يقرأ الملفات:
`packages/data/test/static_catch_rules_test.dart` (يُقرأ مع `flutter test`)، ويطبق
بالضبط:

1. صفر `catch (_` (bare-underscore) في `packages/data/lib` و `packages/core/lib`
   و `apps/mobile/lib` و `apps/desktop/lib` لغير المقيّدة.
2. صفر `catch` غير مقيّد جسمُه يخلو من
   `throw` / `rethrow` / `debugPrint(` / `print(` في `packages/data/lib`
   و `packages/core/lib`.

## حدٌّ مقصود يستحق التوثيق

مسار fallback في المستودعات (مثل قراءة كاش محلي عند انقطاع الشبكة) لا يُحوَّل
إلى `SyncFailure` — **يُبقي القيمة المحلية ويعيدها**، لكنه الآن يطبع السبب
بـ`debugPrint`. السبب: «هبوط» البعيدة هنا ليس خطأً للعرض؛ هو الوضع الطبيعي
لـ Offline-first. قلبُه إلى رميٍ سيكسر الأجهزة بلا اتصال.

انتبه للفرق بين `Exception` و `Error` عند تضييق الالتقاط: مسارات تلمس
`StateError`/أخطاء برمجية (مثل `_remoteDatasource?.currentUid`) تُبقي `catch (e)`
العريض **مع طبع**، ولا تُضيَّق إلى `on Exception` — التضييق قد يحوّل تصرّفاً
سابقاً (صبّ fallback) إلى انفجارٍ غير مخصص.

## ماذا يعني «صاخب» على الخادم أيضاً

العميل لا يمكنه أن يكون صاخباً وحده: `supabase/tests/p0_catch_test.sql`
(مجموعة **4o** في `run_all.py`) تثبت الجانب الخادمي للعقد:

- سطح RPC الذي يستدعيه العميل مكتمل (لا `404` صامت بدل دالة مفقودة).
- `anon` محروم من المسارات المحمية (الرفض صريح وراء مسار catch في التطبيق)،
  و`authenticated` ممنوح المسارات المصرح بها حقاً.
- بلا جلسة، الخادم **يرمي** برموز مقروءة (`AUTHORIZATION_DENIED`) بدل
  نجاحٍ فارغ — وأخطاء الدفعات الكاملة في `sync_records_batch` مصممة
  بـ`RAISE EXCEPTION`، بينما أخطاء كل سجل تظهر في `status` (لا تُبتلع).

## مقاييس M10 (نتيجة الهدم)

- `packages/data/lib`: `0` من `catch (_)`، `0` من non الصامتة.
- `packages/core/lib`: `0` من `catch (_)`، `0` صامت.
- `apps/*/lib`: `0` من `catch (_)` (البقايا الوحيدة داخل
  `build/windows/flutter/ephemeral/.plugin_symlinks` — نواتج Flutter SDK، لا كودنا).
- كل استبدال في الـ sweep له شاهد: اختبارات `flutter test` تُشغّل مسارات fallback
  المطبوعة (تظهر أسطر `madjana: … offline …` في ناتج الاختبارات)،
  و`p0_catch_test.sql` يغطّي العقد الخادمي.

## ملاحظة معروفة (خارج نطاق M10)

بعض ملفات `datasources/remote/*` وقلة قليلة من الملفات الأخرى تحوي تعليقات
عربية مشوّهة الترميز (`±`/`¹`…) **قائمة أصلاً في HEAD** قبل M10 (أثبتناها
بمطابقة HEAD مع الـ working tree سطراً سطراً). لم تُلمَس في هذا العمل كي لا
يُلوَّث التزام W3 بغير موضوعه؛ تنظيفها عمل مستقل لو رغبنا به لاحقاً.

## الاختبارات

- `packages/data/test/static_catch_rules_test.dart` — الإنفاذ الثابت.
- `supabase/tests/p0_catch_test.sql` — عقد الفشل الصاخب الخادمي.
- `flutter test` — كل مسارات fallback المطبوعة تُنفَّذ فعلًا في الاختبارات.