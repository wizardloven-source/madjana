import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:data/data.dart';
import 'app.dart';
import 'core/supabase_client.dart';
import 'core/theme.dart';

/// نقطة دخول تطبيق الموبايل
///
/// Offline-first: قاعدة البيانات المحلية هي شرط التشغيل الأساسي،
/// بينما Supabase اختياري (يُفتح التطبيق حتى لو انقطع الاتصال).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ProviderScope واحد فقط على مستوى الجذر — منعاً لأي تداخل بين النطاقات
  runApp(const ProviderScope(child: MadjanaBootstrap()));
}

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
    } catch (e) {
      debugPrint('madjana: bootstrap .env load: $e');
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
    } catch (e) {
      debugPrint('madjana: bootstrap initial backup: $e');
    }

    // 3. Supabase: اختياري — التطبيق يعمل دون قطع الوصول حتى لو فشلت التهيئة.
    //    استعادة الجلسة تتم لاحقاً عبر authProvider في شاشة التحميل.
    try {
      await SupabaseConfig.initialize();
    } catch (e) {
      // Offline mode: يعمل التطبيق محلياً وتُحفظ التغييرات للمزامنة لاحقاً
      debugPrint('Supabase init deferred (offline mode): $e');
    }

    if (!mounted) return;

    // 4. بوابة إصدار المخطط (M9 — docs/SYNC.md): تقارن إصدار الخادم
    //    (current_schema_version RPC) مع إصدار المخطط المحلي قبل فتح
    //    الواجهة. عند التطابق → تمرير. عند اختلاف الرقمين → حظر المزامنة
    //    حتى يُحدَّث الجانب الأقدم. عند فشل الاتصال → لا حظر (Offline-first).
    final versionBlock = await _checkSchemaVersionGate();
    if (!mounted) return;
    if (versionBlock != null) {
      setState(() => _error = versionBlock);
      return;
    }

    setState(() => _ready = true);
  }

  /// بإرجاع رسالة حظر إن اختلف إصدارا المخطط (الخادم مقابل المحلي)،
  /// و null عند تطابقهما أو تعذّر قراءة أيٍّ منهما (offline).
  Future<String?> _checkSchemaVersionGate() async {
    final client = SupabaseConfig.client;
    if (client == null) return null;
    try {
      final server =
          await SupabaseClientApiAdapter(client).fetchServerSchemaVersion();
      final local = await LocalDatabase.getLocalSchemaVersion();
      if (server > local) {
        return 'إصدار الخادم ($server) أحدث من التطبيق ($local) — حدّث التطبيق';
      }
      if (local > server) {
        return 'التطبيق ($local) أحدث من الخادم ($server) — ينتظر دعم الخادم';
      }
    } catch (e) {
      debugPrint('M9 schema version gate: skipped (offline): $e');
    }
    return null;
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
      } catch (e) {
        debugPrint('madjana: local db open/verify: $e');
        return false;
      }
    }

    if (await tryOpenAndVerify()) return true;

    // فشل الفتح الأول — إعادة فتح نظيف (ليست "إصلاحاً"، فقط فتح جديد)
    try {
      await LocalDatabase.close();
      if (await tryOpenAndVerify()) return true;
    } catch (e) {
      debugPrint('madjana: local db close/reopen: $e');
    }

    // ملاذ أخير: نسخ احتياطي ثم محاولة الاسترجاع
    try {
      await LocalDatabase.backupDatabase();
      return await LocalDatabase.restoreLatestBackup();
    } catch (e) {
      debugPrint('madjana: local db restore fallback: $e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'إدارة المداجن',
      theme: AppTheme.lightTheme(),
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
