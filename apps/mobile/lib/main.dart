import 'dart:io' show Platform;
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
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {}

  // تهيئة Supabase
  try {
    await SupabaseConfig.initialize();
  } catch (e) {
    debugPrint('Supabase init error: $e');
  }

  // تهيئة قاعدة البيانات المحلية (مع حماية من التلف)
  try {
    await LocalDatabase.database;
  } catch (_) {
    try {
      await LocalDatabase.close();
      await LocalDatabase.database;
    } catch (_) {}
  }

  runApp(const ProviderScope(child: PoultryApp()));
}
