# دليل معالجة الأخطاء

## المشكلة
تم العثور على 45+ حالة `catch (_)` تتجاهل الأخطاء بدون تسجيل أو معالجة مناسبة.

## الحل المطبق
تم إصلاح الملفات الحرجة التالية:
- ✅ `apps/mobile/lib/core/supabase_client.dart` - إضافة تحقق من المفاتيح وتسجيل الأخطاء
- ✅ `apps/desktop/lib/core/supabase_client.dart` - إضافة تحقق من المفاتيح وتسجيل الأخطاء
- ✅ `packages/data/lib/src/datasources/local/daos/session_dao.dart` - تسجيل أخطاء فك التشفير
- ✅ `packages/data/lib/src/repositories/auth_repository_impl.dart` - تسجيل جميع الأخطاء

## الإصلاحات المتبقية
الملفات التي لا تزال تحتوي على `catch (_)`:

### ملفات Repository (الأولوية العالية)
- `sync_repository_impl.dart` - أسطر 197, 201, 344
- `feed_repository_impl.dart` - سطر 97
- `medication_repository_impl.dart` - سطر 34
- `dispatch_repository_impl.dart` - سطر 32
- `inventory_repository_impl.dart` - أسطر 31, 47, 57, 92, 106
- `flock_repository_impl.dart` - أسطر 26, 42, 52, 62
- `expense_repository_impl.dart` - أسطر 35, 56, 66

### ملفات DataSource (الأولوية المتوسطة)
- `local_database.dart` - سطر 407
- `supabase_dispatch_datasource.dart` - سطر 27
- `supabase_auth_datasource.dart` - سطر 92
- `supabase_mortality_datasource.dart` - سطر 45
- `supabase_feed_datasource.dart` - أسطر 34, 46
- `supabase_medication_datasource.dart` - سطر 21

### ملفات UI (الأولوية المنخفضة)
- `mobile/lib/main.dart` - سطر 18
- `mobile/lib/features/notifications/providers/notifications_provider.dart` - سطر 24
- `mobile/lib/features/notes/presentation/notes_screen.dart` - أسطر 50, 87
- `mobile/lib/features/notes/presentation/note_composer.dart` - أسطر 81, 98
- `mobile/lib/features/dispatch/providers/dispatch_provider.dart` - سطر 74
- `mobile/lib/features/dispatch/presentation/dispatch_screen.dart` - سطر 210
- `mobile/lib/features/auth/providers/auth_provider.dart` - سطر 55
- `mobile/lib/features/sync/data/sync_engine.dart` - سطر 77
- `desktop/lib/main.dart` - أسطر 27, 34
- `desktop/lib/features/approvals/presentation/approvals_screen.dart` - أسطر 57, 70
- `desktop/lib/features/notifications/presentation/notifications_screen.dart` - سطر 62
- `desktop/lib/features/dispatch/presentation/dispatch_screen.dart` - سطر 57
- `desktop/lib/features/egg_production/presentation/egg_production_screen.dart` - سطر 45
- `desktop/lib/features/dashboard/presentation/dashboard_screen.dart` - أسطر 59, 117, 120

## النمط الموصى به

```dart
// ❌ خطأ: تجاهل الخطأ
try {
  await someOperation();
} catch (_) {}

// ✅ صحيح: تسجيل الخطأ
try {
  await someOperation();
} catch (e) {
  print('فشل العملية: $e');
  // أو استخدام نظام logging متقدم
  logger.e('فشل someOperation', error: e);
}

// ✅ أفضل: معالجة أنواع محددة من الأخطاء
try {
  await someOperation();
} on NetworkException catch (e) {
  // معالجة أخطاء الشبكة
  showOfflineMessage();
} on ValidationException catch (e) {
  // معالجة أخطاء التحقق
  showValidationError(e.message);
} catch (e) {
  // أي خطأ آخر
  logger.e('خطأ غير متوقع', error: e, stackTrace: StackTrace.current);
  showGenericError();
}
```

## الخطوات التالية

1. **إنشاء Logger مركزي** (أولوية عالية)
   ```dart
   class AppLogger {
     static void e(String message, {Object? error, StackTrace? stackTrace}) {
       // إرسال إلى خدمة تتبع الأخطاء (Sentry, Firebase Crashlytics)
       // حفظ محلياً في ملف
       // طباعة في console للتطوير
     }
   }
   ```

2. **إصلاح جميع حالات catch (_)** (أولوية عالية)
   - استبدال كل `catch (_) {}` بـ `catch (e) { AppLogger.e(...); }`
   - إضافة `StackTrace.current` للأخطاء الحرجة

3. **إضافة اختبارات للأخطاء** (أولوية متوسطة)
   - اختبار سلوك التطبيق عند فشل الشبكة
   - اختبار سلوك التطبيق عند بيانات فاسدة

4. **دمج خدمة تتبع الأخطاء** (أولوية منخفضة)
   - Sentry أو Firebase Crashlytics
   - تتبع الأخطاء في الإنتاج
