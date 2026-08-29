import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// إعدادات Supabase Client
///
/// تُقرأ المفاتيح من ملف `.env` (SUPABASE_URL, SUPABASE_ANON_KEY)
/// مع قيم احتياطية للطواريء.
class SupabaseConfig {
  static const String _fallbackUrl = 'https://iefwbcwhpyajhohpxwmj.supabase.co';
  static const String _fallbackKey = 'sb_publishable_oVQbOeVQVgJFTpvh6GvroQ_eoY_dZzE';

  static String get supabaseUrl =>
      dotenv.env['SUPABASE_URL'] ?? _fallbackUrl;
  static String get supabaseAnonKey =>
      dotenv.env['SUPABASE_ANON_KEY'] ?? _fallbackKey;

  static bool _initialized = false;
  static bool get isReady => _initialized;

  /// تهيئة Supabase
  static Future<void> initialize() async {
    if (_initialized) return;

    // التحقق من صحة المفاتيح أولاً
    final url = supabaseUrl;
    final key = supabaseAnonKey;
    if (url.isEmpty || key.isEmpty) {
      throw Exception('Supabase URL أو API key فارغ — تحقق من ملف .env');
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

  /// اختبار الاتصال بالسيرفر
  static Future<String> testConnection() async {
    final url = supabaseUrl;
    final key = supabaseAnonKey;
    final buffer = StringBuffer();
    buffer.writeln('URL: $url');
    buffer.writeln('Key: ${key.substring(0, key.length > 20 ? 20 : key.length)}...');
    buffer.writeln('Initialized: $_initialized');
    return buffer.toString();
  }

  /// الحصول على Client
  static SupabaseClient get client => Supabase.instance.client;
}
