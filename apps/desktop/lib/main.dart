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

  // تهيئة window_manager لضبط حجم وموقع النافذة — لا نستخدم setBackgroundColor
  // لأنّه يلوّن إطار النافذة عبر DWM قبل رسم إطار Flutter الأول، فإذا تأخّر
  // رسم المحتوى يظهر إطار رمادي فارغ بدون محتوى Flutter.
  if (Platform.isWindows) {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setSize(const Size(1280, 800));
      await windowManager.center();
      await windowManager.setTitle('madjana - نظام إدارة المداجن');
    } catch (e) {
      debugPrint('madjana: window init skipped: $e');
    }
  }

  // ===== الحل الجديد: تهيئة قاعدة البيانات لـ Windows =====
  if (Platform.isWindows) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // تحميل المفاتيح من ملف .env
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    debugPrint('madjana: dotenv load skipped: $e');
  }

  // تهيئة Supabase (مع تجاهل الأخطاء إذا كانت المفاتيح غير جاهزة)
  // CR-4 FIX: مهلة 8 ثوانٍ — Supabase.initialize() يعلق بلا مهلة إذا كان
  // الخادم غير متاح، فيبقى التطبيق على شاشة خلفية رمادية إبدئاً.
  try {
    await SupabaseConfig.initialize().timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        debugPrint('madjana: supabase init timed out — running offline');
        return null;
      },
    );
  } catch (e) {
    debugPrint('madjana: supabase init skipped: $e');
  }

  // ثبات مسار قاعدة البيانات المحلية على Windows
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    final dbDir = Directory(p.join(appData, 'madjana'));
    dbDir.createSync(recursive: true);
    LocalDatabase.setDatabasePath(p.join(dbDir.path, LocalDatabase.dbName));
  }

  // تهيئة قاعدة البيانات المحلية — مهلة 10 ثوانٍ
  try {
    await LocalDatabase.database.timeout(const Duration(seconds: 10));
  } catch (e) {
    debugPrint('madjana: local DB init timed out — will retry lazily');
  }

  // بوابة عقد المزامنة (M9) — مهلة 12 ثانية
  final startupBlock = await _schemaVersionBlock().timeout(
    const Duration(seconds: 12),
    onTimeout: () {
      debugPrint('madjana: sync contract block timed out — proceeding unblocked');
      return null;
    },
  );

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