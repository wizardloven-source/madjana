import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// إعدادات Supabase Client
///
/// تُقرأ المفاتيح من ملف `.env` (SUPABASE_URL, SUPABASE_ANON_KEY)
/// مع قيم احتياطية للطواريء.
class SupabaseConfig {
  static const String _fallbackUrl = 'https://YOUR_PROJECT.supabase.co';
  static const String _fallbackKey = 'YOUR_ANON_KEY';

  static String get supabaseUrl =>
      dotenv.env['SUPABASE_URL'] ?? _fallbackUrl;
  static String get supabaseAnonKey =>
      dotenv.env['SUPABASE_ANON_KEY'] ?? _fallbackKey;

  /// تهيئة Supabase
  static Future<void> initialize() async {
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
  }

  /// الحصول على Client
  static SupabaseClient get client => Supabase.instance.client;
}