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

  /// هل يوجد سوبر أدمن في النظام؟
  /// (تعمل قبل الدخول — تتحقق من users بدون كشف بيانات)
  Future<bool?> hasSystemAdmin() async {
    try {
      final res = await _client
          .rpc('has_system_admin')
          .timeout(const Duration(seconds: 8), onTimeout: () {
        throw AuthException('انتهت مهلة الاتصال بالسيرفر');
      });
      return res == true;
    } catch (_) {
      // تعذّر الوصول -> لا نجزم بوجود/عدم وجود (فلا نعرض شاشة إنشاء بطريقة خاطئة)
      return null;
    }
  }

  /// إنشاء أول سوبر أدمن (مزرعة + مدير النظام) — التشغيل الأول فقط.
  /// لا يتطلب رمز تزويد خارجي (تُقرأ داخلياً في SQL).
  Future<void> createFirstAdmin({
    required String farmName,
    String? location,
    required String managerName,
    required String phone,
    required String pin,
  }) async {
    phone = _normalizeDigits(phone);
    pin = _normalizeDigits(pin);

    if (farmName.trim().isEmpty || managerName.trim().isEmpty) {
      throw AuthException('أدخل اسم المزرعة واسم المسؤول');
    }
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      throw AuthException('الرمز السري يجب أن يكون 4 أرقام');
    }
    if (phone.isEmpty) {
      throw AuthException('أدخل رقم الهاتف');
    }

    try {
      final res = await _client.rpc('create_first_admin', params: {
        'p_farm_name': farmName.trim(),
        'p_location': location?.trim() ?? '',
        'p_manager_name': managerName.trim(),
        'p_phone': phone,
        'p_pin': pin,
      }).timeout(const Duration(seconds: 25), onTimeout: () {
        throw AuthException('انتهت مهلة إنشاء الحساب');
      });

      // التحقق من النتيجة قبل المتابعة
      final map = _asMap(res);
      final uid = map?['user_id'] as String?;
      if (uid == null || uid.isEmpty) {
        throw AuthException('لم يتم إنشاء الحساب — أعد المحاولة');
      }
    } on PostgrestException catch (e) {
      throw AuthException('فشل إنشاء الحساب: ${e.message}');
    } catch (e) {
      if (e is AuthException) rethrow;
      final msg = e.toString();
      if (msg.contains('SocketException') || msg.contains('errno = 7')) {
        throw AuthException('لا يوجد اتصال بالإنترنت — تحقق من الشبكة');
      }
      if (msg.contains('TimeoutException') || msg.contains('timeout')) {
        throw AuthException('انتهت مهلة الاتصال — تحقق من سرعة الإنترنت');
      }
      throw AuthException('فشل إنشاء الحساب: $msg');
    }
  }

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
      // 0) فحص قفل الحساب قبل أي محاولة (قفل PIN + حدّ معدل)
      final preCheck = await _client
          .rpc('check_login_allowed', params: {'p_phone': phone})
          .timeout(const Duration(seconds: 10), onTimeout: () {
        throw AuthException('انتهت مهلة الاتصال بالسيرفر');
      });
      final pre = _asMap(preCheck);
      if (pre?['allowed'] == false) {
        final lockSeconds = (pre?['lock_seconds'] as num?)?.toInt() ?? 0;
        if ((pre?['locked'] == true) && lockSeconds > 0) {
          throw AuthException('الحساب مقفل مؤقتاً — أعد المحاولة بعد ${((lockSeconds + 59) ~/ 60)} دقيقة');
        }
        throw AuthException('محاولات كثيرة — انتظر قليلاً ثم أعد المحاولة');
      }

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

      // 2b) تسجيل النجاح: تصفير العدّاد ورفع القفل
      try {
        await _client.rpc('record_login_success', params: {'p_uid': uid});
      } catch (_) {
        // عدم نجاح التسجيل لا يمنع الدخول
      }

      // 3) الدور/المزرعة تُقرأ من الـ JWT (مصدر مُصادَق) وليس من البحث المكشوف
      // (find_user_by_phone لا يعيد إلا id لمنع تعداد المستخدمين — نقطة #6)
      final sessionUser = _client.auth.currentUser;
      final meta = sessionUser?.userMetadata ?? const {};
      final resolvedName = (meta['full_name'] as String?) ?? '';
      final resolvedPhone = (meta['phone'] as String?) ?? phone;
      final resolvedRole = (meta['role'] as String?) ?? 'worker';
      final resolvedFarmId = (meta['farm_id'] as String?) ?? '';

      // 3b) كل المداجن المرتبط بها المستخدم (لتمكين الربط المتعدد)
      final farmIds = await _fetchCurrentUserFarmIds();
      final activeFarmId = resolvedFarmId.isNotEmpty
          ? resolvedFarmId
          : (farmIds.isNotEmpty ? farmIds.first : '');

      return UserModel.fromJson({
        'uid': uid,
        'name': resolvedName,
        'phone': resolvedPhone,
        'role': resolvedRole,
        'farm_id': activeFarmId,
        'farm_ids': farmIds,
        'created_at': null,
      });
    } on AuthApiException catch (e) {
      // أخطاء GoTrue (بريد/كلمة مرور خاطئة أو حساب غير مفعل)
      final msg = (e.message).toLowerCase();
      if (msg.contains('invalid login')) {
        // تسجيل المحاولة الفاشلة (لقفل الحساب عند التكرار)
        try {
          await _client.rpc('record_login_failure', params: {'p_phone': phone});
        } catch (_) {}
        throw AuthException('الرمز السري غير صحيح');
      }
      if (msg.contains('not confirmed')) {
        throw AuthException('الحساب غير مفعّل - تواصل مع المدير');
      }
      throw AuthException('فشل تسجيل الدخول: ${e.message}');
    } on PostgrestException catch (e) {
      final msg = (e.message).toLowerCase();
      if (msg.contains('محاولات كثيرة') || msg.contains('authorization_denied')) {
        throw AuthException('محاولات كثيرة — انتظر قليلاً ثم أعد المحاولة');
      }
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

  /// تحويل رد RPC إلى خريطة (أمان: يتعامل مع الأشكال المختلفة)
  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    if (value is List && value.isNotEmpty && value.first is Map) {
      return Map<String, dynamic>.from(value.first as Map);
    }
    return null;
  }

  /// جلب معرّفات المداجن المرتبط بها المستخدم الحالي (آمنة: تعيد ما يخصّه فقط)
  Future<List<String>> _fetchCurrentUserFarmIds() async {
    try {
      final rows = await _client
          .rpc('current_user_farm_ids')
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      if (rows is! List) return const [];
      return rows
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// تحديد المدجنة النشطة للمستخدم الحالي وإعادة صورة المستخدم المحدّثة
  Future<UserModel?> setActiveFarm(String farmId) async {
    final res = await _client
        .rpc('set_active_farm', params: {'p_farm_id': farmId})
        .timeout(const Duration(seconds: 10), onTimeout: () => null);
    final map = _asMap(res);
    if (map == null) return null;
    final farmIds = await _fetchCurrentUserFarmIds();
    return UserModel.fromJson({
      'uid': map['id'],
      'name': map['name'],
      'phone': map['phone'],
      'role': map['role'],
      'farm_id': map['farm_id'] ?? (farmIds.isNotEmpty ? farmIds.first : null),
      'farm_ids': farmIds,
      'is_active': map['is_active'],
      'created_at': map['created_at'],
    });
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
      final map = <String, dynamic>{
        'uid': data['id'],
        'name': data['name'],
        'phone': data['phone'],
        'role': data['role'],
        'farm_id': data['farm_id'],
        'created_at': data['created_at'],
      };
      if (uid == currentUid) {
        final farmIds = await _fetchCurrentUserFarmIds();
        if (farmIds.isNotEmpty) map['farm_ids'] = farmIds;
      }
      return map;
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
