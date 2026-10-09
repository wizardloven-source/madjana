import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:data/data.dart';
import 'app.dart';
import 'core/supabase_client.dart';

// أضف هذه المكتبات الجديدة
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// نقطة دخول تطبيق سطح المكتب (للمدير)
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ===== الحل الجديد: تهيئة قاعدة البيانات لـ Windows =====
  // هذا السطر يحل مشكلة databaseFactory
  if (Platform.isWindows) {
    sqfliteFfiInit();  // تهيئة FFI لقاعدة البيانات
    databaseFactory = databaseFactoryFfi;  // تعيين المصنع
  }
  // ========================================================

  // تحميل المفاتيح من ملف .env
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    debugPrint('madjana: dotenv load skipped: $e');
    // بدون مفاتيح يعمل التطبيق وضع Offline حتى ضبط الإعدادات
  }

  // تهيئة Supabase (مع تجاهل الأخطاء إذا كانت المفاتيح غير جاهزة)
  try {
    await SupabaseConfig.initialize();
  } catch (e) {
    debugPrint('madjana: supabase init skipped: $e');
    // يعمل وضع Offline حتى ضبط الإعدادات
  }

  // ===== ثبات مسار قاعدة البيانات المحلية على Windows =====
  // آمن وقف التشعب: القاعدة توضع في مجلد ثابت على مستوى المستخدم
  // بدلاً من دليل العمل، حتى لا تختلف بين تشغيلٍ وآخر.
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    final dbDir = Directory(p.join(appData, 'madjana'));
    dbDir.createSync(recursive: true);
    LocalDatabase.setDatabasePath(p.join(dbDir.path, LocalDatabase.dbName));
  }

  // تهيئة قاعدة البيانات المحلية
  await LocalDatabase.database;

  // بوابة إصدار المخطط (M9 — docs/SYNC.md): عند اختلاف إصدار الخادم
  // عن المحلي نمنع فتح الواجهة حتى يُحدَّث الجانب الأقدم. فشل الاتصال
  // (offline) يُتخطى — التطبيق يفتح دائماً.
  final startupBlock = await _schemaVersionBlock();

  runApp(ProviderScope(
    child: MadjanaDesktopApp(startupBlockMessage: startupBlock),
  ));
}

/// رسالة حظر الإقلاع عند تعارض إصدار المخطط بين الخادم والتطبيق، أو null
/// عند تطابقهما أو تعذّر قراءة أحدهما (offline). تفاصيل العقد في docs/SYNC.md.
Future<String?> _schemaVersionBlock() async {
  if (!SupabaseConfig.isReady) return null;
  try {
    final server = await SupabaseClientApiAdapter(SupabaseConfig.client)
        .fetchServerSchemaVersion();
    final local = await LocalDatabase.getLocalSchemaVersion();
    if (server > local) {
      return 'إصدار الخادم ($server) أحدث من التطبيق ($local) — حدّث التطبيق';
    }
    if (local > server) {
      return 'التطبيق ($local) أحدث من الخادم ($server) — ينتظر دعم الخادم';
    }
  } catch (e) {
    debugPrint('M9 schema version block: skipped (offline): $e');
  }
  return null;
}