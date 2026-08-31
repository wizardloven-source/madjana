import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:data/data.dart';
import 'app.dart';
import 'core/supabase_client.dart';
import 'config/app_theme.dart';

/// نقطة دخول تطبيق الموبايل
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const ProviderScope(child: MadjanaBootstrap()));
}

/// حالة تهيئة التطبيق
class MadjanaBootstrap extends StatefulWidget {
  const MadjanaBootstrap({super.key});

  @override
  State<MadjanaBootstrap> createState() => _MadjanaBootstrapState();
}

enum _InitStep { dotenv, supabase, database }

class _MadjanaBootstrapState extends State<MadjanaBootstrap> {
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      _ready = false;
      _error = null;
    });

    // 1. تحميل .env (اختياري - قد لا يوجد في الوضع المحلي)
    try {
      await dotenv.load(fileName: '.env');
    } catch (_) {
      // لا يوجد ملف .env — يستمر بدون مفاتيح
    }

    // 2. تهيئة Supabase
    try {
      await SupabaseConfig.initialize();
    } catch (e) {
      setState(() => _error = 'خطأ في تهيئة Supabase: $e');
      return;
    }

    // 3. تهيئة قاعدة البيانات المحلية (مع محاولة إصلاح التلف)
    final dbInitialized = await _initLocalDatabase();
    if (!dbInitialized) {
      setState(() => _error = 'تعذر فتح قاعدة البيانات المحلية');
      return;
    }

    if (!mounted) return;
    setState(() => _ready = true);
  }

  /// تهيئة قاعدة البيانات مع محاولة إصلاح التلف
  Future<bool> _initLocalDatabase() async {
    try {
      await LocalDatabase.database;
      return true;
    } catch (_) {
      try {
        await LocalDatabase.close();
        await LocalDatabase.database;
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'إدارة المداجن',
      theme: AppTheme.lightTheme,
      locale: const Locale('ar', 'SA'),
      debugShowCheckedModeBanner: false,
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (!_ready) {
      return Scaffold(
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 48, color: Colors.red),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _boot,
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
        ),
      );
    }
    return const ProviderScope(child: PoultryApp());
  }
}
