import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// إعدادات Supabase Client
///
/// تُقرأ المفاتيح من ملف `.env` (SUPABASE_URL, SUPABASE_ANON_KEY)
/// مع قيم احتياطية للطواريء.
/// 
/// ⚠️ تحذير أمني: القيم الافتراضية يجب إزالتها قبل الإنتاج
class SupabaseConfig {
  static const String _fallbackUrl = 'https://YOUR_PROJECT.supabase.co';
  static const String _fallbackKey = 'YOUR_ANON_KEY';
  
  static String get supabaseUrl {
    final url = dotenv.env['SUPABASE_URL'];
    if (url == null || url.isEmpty) {
      throw StateError(
        'SUPABASE_URL غير موجود في ملف .env. '
        'يرجى إنشاء ملف .env وإضافة مفاتيح Supabase الخاصة بك. '
        'راجع .env.example للمثال.',
      );
    }
    return url;
  }
  
  static String get supabaseAnonKey {
    final key = dotenv.env['SUPABASE_ANON_KEY'];
    if (key == null || key.isEmpty) {
      throw StateError(
        'SUPABASE_ANON_KEY غير موجود في ملف .env. '
        'يرجى إنشاء ملف .env وإضافة مفاتيح Supabase الخاصة بك.',
      );
    }
    return key;
  }

  /// تهيئة Supabase
  static Future<void> initialize() async {
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        publishableKey: supabaseAnonKey,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
        ),
      );
    } catch (e) {
      throw Exception('فشل تهيئة Supabase: $e');
    }
  }

  /// الحصول على Client
  static SupabaseClient get client => Supabase.instance.client;
}
