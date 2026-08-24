import 'dart:convert';

import 'package:core/core.dart';
import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات المصادقة عبر Supabase Auth الحقيقي
///
/// الآلية:
/// 1. البحث عن المستخدم بالهاتف (دالة RPC تعمل قبل الدخول)
/// 2. الدخول بـ signInWithPassword:
///    - البريد الاصطناعي: <uid>@users.madjana.local
///    - كلمة المرور: sha256(PIN)
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
      );
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
      );

      return UserModel.fromJson({
        'uid': uid,
        'name': userData['name'],
        'phone': userData['phone'],
        'role': userData['role'],
        'farm_id': userData['farm_id'],
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
      throw AuthException('فشل تسجيل الدخول: $e');
    }
  }

  /// جلب مستخدم بالمعرّف
  Future<Map<String, dynamic>?> getUserById(String uid) async {
    try {
      final data =
          await _client.from('users').select().eq('id', uid).maybeSingle();
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

  /// تشفير PIN (SHA-256 hex) — يُستخدم ككلمة مرور لدى Supabase Auth
  /// ويجب أن يطابق دالة app_password_from_pin في قاعدة البيانات
  String _hashPin(String pin) {
    final bytes = utf8.encode(pin);
    return sha256.convert(bytes).toString();
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
