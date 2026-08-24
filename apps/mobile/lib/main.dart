import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:data/data.dart';
import 'app.dart';
import 'core/supabase_client.dart';

/// نقطة دخول تطبيق الموبايل
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // تحميل المفاتيح من ملف .env
  await dotenv.load(fileName: '.env');

  // تهيئة Supabase (مع تجاهل الأخطاء إذا كانت المفاتيح غير جاهزة)
  try {
    await SupabaseConfig.initialize();
  } catch (_) {
    // التطبيق يعمل وضع Offline-only حتى ضبط الإعدادات
  }

  // تهيئة قاعدة البيانات المحلية
  await LocalDatabase.database;

  runApp(const ProviderScope(child: PoultryApp()));
}