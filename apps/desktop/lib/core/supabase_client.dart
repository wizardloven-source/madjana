import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// إعدادات Supabase Client (سطح المكتب - للمدير)
///
/// تُقرأ المفاتيح من ملف `.env` (SUPABASE_URL, SUPABASE_ANON_KEY)
/// أو من --dart-define عند البناء. لا يوجد أي fallback للإنتاج —
/// التطبيق يعمل Offline-first حتى تتوفر المفاتيح.
class SupabaseConfig {
  static const String _defineUrl = String.fromEnvironment('SUPABASE_URL');
  static const String _defineKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static String? get supabaseUrl {
    final fromEnv = dotenv.env['SUPABASE_URL'];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    if (_defineUrl.isNotEmpty) return _defineUrl;
    return null;
  }

  static String? get supabaseAnonKey {
    final fromEnv = dotenv.env['SUPABASE_ANON_KEY'];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    if (_defineKey.isNotEmpty) return _defineKey;
    return null;
  }

  static bool _initialized = false;
  static bool get isReady => _initialized;

  /// تهيئة Supabase
  static Future<void> initialize() async {
    if (_initialized) return;

    final url = supabaseUrl;
    final key = supabaseAnonKey;
    if (url == null || url.isEmpty || key == null || key.isEmpty) {
      throw Exception('Supabase URL أو API key غير متوفر — مرّرها عبر --dart-define أو ملف .env');
    }

    await Supabase.initialize(
      url: url,
      publishableKey: key,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );

    _initialized = true;
  }

  /// الحصول على Client
  static SupabaseClient get client => Supabase.instance.client;
}
