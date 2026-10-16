import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'package:data/data.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'core/supabase_client.dart';

// أضف هذه المكتبات الجديدة
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// نقطة دخول تطبيق سطح المكتب (للمدير)
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // نافذة داكنة من اللحظة الأولى — لا وميض أبيض قبل رسم السبلاش.
  // setBackgroundColor يرسم خلفية النافذة عبر DWM فوراً، قبل أول إطار Flutter.
  if (Platform.isWindows) {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setBackgroundColor(const Color(0xFF0D0D0D));
    } catch (e) {
      debugPrint('madjana: window background init skipped: $e');
    }
  }

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

  // بوابة عقد المزامنة (M9 — docs/SYNC.md): عند اختلاف **عقد العميل**
  // (kSyncContractVersion) عن إصدار الخادم نمنع فتح الواجهة حتى يُحدَّث
  // الجانب الأقدم. الرقم المحلي `_dbVersion` (ترحيلات SQLite) محلي بحت ولا
  // يُقارن بالخادم. فشل الاتصال (offline) يُتخطى — التطبيق يفتح دائماً.
  final startupBlock = await _schemaVersionBlock();

  runApp(ProviderScope(
    child: MadjanaDesktopApp(startupBlockMessage: startupBlock),
  ));
}

/// رسالة حظر الإقلاع عند كون الخادم أحدث من عقد التطبيق، أو null عند التطابق
/// أو كون العقد أحدث من الخادم (تحذير فقط) أو تعذّر القراءة (offline).
/// تفاصيل العقد في docs/SYNC.md.
Future<String?> _schemaVersionBlock() async {
  if (!SupabaseConfig.isReady) return null;
  try {
    final server = await SupabaseClientApiAdapter(SupabaseConfig.client)
        .fetchServerSchemaVersion();
    final state = evaluateSyncContract(
      contractVersion: kSyncContractVersion,
      serverVersion: server,
    );
    switch (state) {
      case SyncContractState.serverAhead:
        return 'إصدار الخادم ($server) أحدث من التطبيق ($kSyncContractVersion)'
            ' — حدّث التطبيق';
      case SyncContractState.clientAhead:
        // تحذير فقط — لا حظر.
        debugPrint('M9 sync gate: client contract ($kSyncContractVersion) '
            'ahead of server ($server) — warning only');
      case SyncContractState.match:
      case SyncContractState.unknown:
        break;
    }
  } catch (e) {
    debugPrint('M9 sync contract block: skipped (offline): $e');
  }
  return null;
}