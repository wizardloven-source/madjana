import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات المصادقة عبر Supabase Auth الحقيقي
///
/// الآلية:
/// 1. البحث عن المستخدم بالهاتف (دالة RPC تعمل قبل الدخول)
/// 2. الدخول بـ signInWithPassword:
///    - البريد الاصطناعي: <uid>@users.madjana.local
///    - كلمة المرور: pepper + PIN (يضاف الـ pepper قبل الإرسال،
///      ويتحقق منها GoTrue عبر bcrypt مماثل لدالة app_password_from_pin)
/// 3. بعد النجاح auth.uid() = معرف المستخدم وتعمل كل سياسات RLS
class SupabaseAuthDatasource {
  final SupabaseClient _client;

  SupabaseAuthDatasource(this._client);

  /// معرف المستخدم من جلسة Supabase الحالية (null إن لم يسجل دخولاً)
  String? get currentUid => _client.auth.currentSession?.user.id;

  /// تسجيل الدخول بالهاتف + PIN
  Future<UserModel> login({
    required String phone,
    required String pin,
  }) async {
    // تطبيع المدخلات: تحويل الأرقام الهندية/الفارسية إلى إنجليزية
    // وإزالة المسافات والشرط من رقم الهاتف (مشكلة شائعة مع لوحات المفاتيح العربية)
    phone = _normalizeDigits(phone);
    pin = _normalizeDigits(pin);

    try {
      // 1) البحث عن المستخدم بالهاتف
      final rows = await _client.rpc(
        'find_user_by_phone',
        params: {'p_phone': phone},
      ).timeout(const Duration(seconds: 10), onTimeout: () {
        throw AuthException('انتهت مهلة الاتصال بالسيرفر');
      });
      final list = (rows as List?) ?? const [];
      if (list.isEmpty) {
        throw AuthException('رقم الهاتف غير مسجل');
      }
      final userData = Map<String, dynamic>.from(list.first as Map);
      final uid = userData['id'] as String;

      // 2) الدخول عبر Supabase Auth
      await _client.auth.signInWithPassword(
        email: _authEmail(uid),
        password: _hashPin(pin),
      ).timeout(const Duration(seconds: 10), onTimeout: () {
        throw AuthException('انتهت مهلة تسجيل الدخول');
      });

      // 3) الدور/المزرعة تُقرأ من الـ JWT (مصدر مُصادَق) وليس من بحث الهاتف المكشوف
      final sessionUser = _client.auth.currentUser;
      final meta = sessionUser?.userMetadata ?? const {};
      final resolvedName = (meta['full_name'] as String?) ?? userData['name'];
      final resolvedPhone = (meta['phone'] as String?) ?? userData['phone'];
      final resolvedRole = (meta['role'] as String?) ?? 'worker';
      final resolvedFarmId = (meta['farm_id'] as String?) ?? '';

      return UserModel.fromJson({
        'uid': uid,
        'name': resolvedName,
        'phone': resolvedPhone,
        'role': resolvedRole,
        'farm_id': resolvedFarmId,
        'created_at': null,
      });
    } on AuthApiException catch (e) {
      // أخطاء GoTrue (بريد/كلمة مرور خاطئة أو حساب غير مفعل)
      final msg = (e.message).toLowerCase();
      if (msg.contains('invalid login')) {
        throw AuthException('الرمز السري غير صحيح');
      }
      if (msg.contains('not confirmed')) {
        throw AuthException('الحساب غير مفعّل - تواصل مع المدير');
      }
      throw AuthException('فشل تسجيل الدخول: ${e.message}');
    } on PostgrestException catch (e) {
      throw AuthException('خطأ في الاتصال: ${e.message}');
    } catch (e) {
      if (e is AuthException) rethrow;
      final msg = e.toString();
      if (msg.contains('SocketException') || msg.contains('errno = 7')) {
        throw AuthException('لا يوجد اتصال بالإنترنت — تحقق من الشبكة وأعد المحاولة');
      }
      if (msg.contains('TimeoutException') || msg.contains('timeout')) {
        throw AuthException('انتهت مهلة الاتصال — تحقق من سرعة الإنترنت');
      }
      throw AuthException('فشل الاتصال بالسيرفر: $msg');
    }
  }

  /// جلب مستخدم بالمعرّف
  Future<Map<String, dynamic>?> getUserById(String uid) async {
    try {
      final data = await _client
          .from('users')
          .select()
          .eq('id', uid)
          .maybeSingle()
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      if (data == null) return null;
      return {
        'uid': data['id'],
        'name': data['name'],
        'phone': data['phone'],
        'role': data['role'],
        'farm_id': data['farm_id'],
        'created_at': data['created_at'],
      };
    } catch (_) {
      return null;
    }
  }

  /// البريد الاصطناعي المرتبط بحساب auth (يجب أن يطابق دالة app_user_email)
  String _authEmail(String uid) => '$uid@users.madjana.local';

  /// تحويل الأرقام الهندية (٠-٩) والفارسية (۰-۹) إلى إنجليزية
  /// وإزالة المسافات والشرطات من المدخل
  String _normalizeDigits(String input) {
    const arabic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    const persian = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
    final buffer = StringBuffer();
    for (final ch in input.runes) {
      final s = String.fromCharCode(ch);
      final ai = arabic.indexOf(s);
      if (ai >= 0) {
        buffer.write(ai);
        continue;
      }
      final pi = persian.indexOf(s);
      if (pi >= 0) {
        buffer.write(pi);
        continue;
      }
      buffer.write(s);
    }
    return buffer.toString().replaceAll(RegExp(r'[\s\-–]'), '');
  }

  /// تحويل PIN إلى "كلمة مرور" تُسلّم لـ GoTrue للتحقق منها بـ bcrypt
  /// يُضاف نفس الـ pepper المطابق لدالة app_password_from_pin في قاعدة البيانات
  /// لمنع هجوم القوة العمياء دون اتصال على رقم PIN من 4 خانات.
  String _hashPin(String pin) {
    return 'madjana\$' + pin;
  }

  /// تسجيل الخروج
  Future<void> logout() async {
    await _client.auth.signOut();
  }
}

/// استثناء المصادقة
class AuthException implements Exception {
  final String message;
  AuthException(this.message);

  @override
  String toString() => message;
}
