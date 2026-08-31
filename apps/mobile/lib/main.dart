import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:data/data.dart';
import 'app.dart';
import 'core/supabase_client.dart';
import 'config/app_theme.dart';

/// نقطة دخول تطبيق الموبايل
///
/// Offline-first: قاعدة البيانات المحلية هي شرط التشغيل الأساسي،
/// بينما Supabase اختياري (يُفتح التطبيق حتى لو انقطع الاتصال).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ProviderScope واحد فقط على مستوى الجذر — منعاً لأي تداخل بين النطاقات
  runApp(const ProviderScope(child: MadjanaBootstrap()));
}

enum _InitStep { database, session, supabase }

/// حالة تهيئة التطبيق (تحت ProviderScope الجذر)
class MadjanaBootstrap extends StatefulWidget {
  const MadjanaBootstrap({super.key});

  @override
  State<MadjanaBootstrap> createState() => _MadjanaBootstrapState();
}

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

    // 1. تحميل .env (اختياري — قد لا يوجد في الوضع المحلي)
    try {
      await dotenv.load(fileName: '.env');
    } catch (_) {
      // لا يوجد ملف .env — يستمر بدون مفاتيح
    }

    // 2. قاعدة البيانات المحلية: MUST WORK (Offline-first)
    //    مع فحص سلامة + نسخ احتياطي قبل أي حذف.
    final dbOk = await _initLocalDatabaseSafely();
    if (!dbOk) {
      if (!mounted) return;
      setState(() => _error = 'تعذر فتح قاعدة البيانات المحلية — البيانات لم تُفقد، أعد المحاولة');
      return;
    }

    // نسخة احتياطية أولية لحماية البيانات المحلية (بما فيها طابور المزامنة)
    try {
      await LocalDatabase.backupDatabase();
    } catch (_) {}

    // 3. Supabase: اختياري — التطبيق يعمل دون قطع الوصول حتى لو فشلت التهيئة.
    //    استعادة الجلسة تتم لاحقاً عبر authProvider في شاشة التحميل.
    try {
      await SupabaseConfig.initialize();
    } catch (e) {
      // Offline mode: يعمل التطبيق محلياً وتُحفظ التغييرات للمزامنة لاحقاً
      debugPrint('Supabase init deferred (offline mode): $e');
    }

    if (!mounted) return;
    setState(() => _ready = true);
  }

  /// فتح قاعدة البيانات مع فحص السلامة ونسخ احتياطي قبل أي محاولة حذف.
  Future<bool> _initLocalDatabaseSafely() async {
    // frame الحماية: لا يُحذف أي شيء دون نسخة احتياطية
    Future<bool> tryOpenAndVerify() async {
      try {
        await LocalDatabase.database;
        final ok = await LocalDatabase.runIntegrityCheck();
        if (!ok) {
          // تالفة — ننسخها احتياطياً ثم نحاول الاسترجاع من آخر نسخة سليمة
          await LocalDatabase.backupDatabase();
          return await LocalDatabase.restoreLatestBackup();
        }
        return true;
      } catch (_) {
        return false;
      }
    }

    if (await tryOpenAndVerify()) return true;

    // فشل الفتح الأول — إعادة فتح نظيف (ليست "إصلاحاً"، فقط فتح جديد)
    try {
      await LocalDatabase.close();
      if (await tryOpenAndVerify()) return true;
    } catch (_) {}

    // ملاذ أخير: نسخ احتياطي ثم محاولة الاسترجاع
    try {
      await LocalDatabase.backupDatabase();
      return await LocalDatabase.restoreLatestBackup();
    } catch (_) {
      return false;
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
    return const PoultryApp();
  }
}
