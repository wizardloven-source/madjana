import 'dart:convert';
import 'dart:io';

import 'package:core/core.dart';
import 'package:crypto/crypto.dart';
import 'package:domain/domain.dart';
import '../datasources/local/daos/session_dao.dart';
import '../datasources/local/daos/settings_dao.dart';
import '../datasources/remote/supabase_auth_datasource.dart';

/// تنفيذ مستودع المصادقة
class AuthRepositoryImpl implements AuthRepository {
  final SupabaseAuthDatasource _remoteDatasource;
  final SessionDao _sessionDao;
  final SettingsDao _settingsDao;

  AuthRepositoryImpl({
    required SupabaseAuthDatasource remoteDatasource,
    required SessionDao sessionDao,
    SettingsDao? settingsDao,
  })  : _remoteDatasource = remoteDatasource,
        _sessionDao = sessionDao,
        _settingsDao = settingsDao ?? SettingsDao();

  @override
  Future<LoginResult> login({
    required String phone,
    required String pin,
    bool rememberMe = false,
  }) async {
    // محاولة الدخول عبر الإنترنت
    try {
      final user = await _remoteDatasource.login(phone: phone, pin: pin);

      // حفظ الجلسة محلياً مع بيانات المستخدم (للاسترجاع بدون إنترنت)
      await _sessionDao.save(
        userId: user.uid,
        farmId: user.farmId ?? '',
        rememberToken: rememberMe ? user.uid : null,
        userJson: jsonEncode(user.toJson()),
      );

      // حفظ بيانات الدخول المحلية للطوارئ (بدون إنترنت)
      try {
        final pinHash = sha256.convert(utf8.encode(pin)).toString();
        await _settingsDao.set('offline_phone', phone);
        await _settingsDao.set('offline_pin_hash', pinHash);
        await _settingsDao.set('offline_user_json', jsonEncode(user.toJson()));
        await _settingsDao.set('offline_farm_id', user.farmId ?? '');
      } catch (_) {}

      return LoginResult.success(user);
    } on AuthException catch (e) {
      // إذا كان الخطأNETWORK → جرّب الدخول المحلي
      if (_isNetworkError(e.message)) {
        return _tryOfflineLogin(phone, pin);
      }
      return LoginResult.failure(e.message);
    } catch (e) {
      if (_isNetworkError(e.toString())) {
        return _tryOfflineLogin(phone, pin);
      }
      return LoginResult.failure('خطأ غير متوقع: $e');
    }
  }

  /// محاولة الدخول من الكاش المحلي عند عدم وجود إنترنت
  Future<LoginResult> _tryOfflineLogin(String phone, String pin) async {
    try {
      final storedPhone = await _settingsDao.get('offline_phone');
      final storedPinHash = await _settingsDao.get('offline_pin_hash');
      final storedUserJson = await _settingsDao.get('offline_user_json');
      final storedFarmId = await _settingsDao.get('offline_farm_id');

      if (storedPhone == null || storedPinHash == null || storedUserJson == null) {
        return LoginResult.failure(
          'لا يوجد اتصال بالإنترنت ولا توجد بيانات محفوظة محلياً — سجّل الدخول أول مرة مع إنترنت',
        );
      }

      // تطبيع رقم الهاتف قبل المقارنة
      final normalizedPhone = _normalizePhone(phone);
      final normalizedStored = _normalizePhone(storedPhone);

      if (normalizedPhone != normalizedStored) {
        return LoginResult.failure('رقم الهاتف غير متطابق مع البيانات المحفوظة محلياً');
      }

      // التحقق من كلمة المرور
      final pinHash = sha256.convert(utf8.encode(pin)).toString();
      if (pinHash != storedPinHash) {
        return LoginResult.failure('الرمز السري غير صحيح');
      }

      // نجاح الدخول المحلي
      final userData = Map<String, dynamic>.from(
        jsonDecode(storedUserJson) as Map,
      );
      final user = UserModel.fromJson(userData);

      await _sessionDao.save(
        userId: user.uid,
        farmId: user.farmId ?? storedFarmId ?? '',
        userJson: storedUserJson,
      );

      return LoginResult.success(user);
    } catch (e) {
      return LoginResult.failure('خطأ في الدخول بدون إنترنت: $e');
    }
  }

  /// تطبيع رقم الهاتف: إزالة المسافات والشرطات
  String _normalizePhone(String phone) {
    return phone.replaceAll(RegExp(r'[\s\-–]'), '').trim();
  }

  /// التحقق مما إذا كان الخطأ مرتبطاً بالشبكة
  bool _isNetworkError(String msg) {
    return msg.contains('SocketException') ||
        msg.contains('errno = 7') ||
        msg.contains('لا يوجد اتصال') ||
        msg.contains('Failed host lookup') ||
        msg.contains('Network is unreachable') ||
        msg.contains('Connection refused') ||
        msg.contains('Connection timed out') ||
        msg.contains('انقطع') ||
        msg.contains('timeout') ||
        msg.contains('TimeoutException') ||
        msg.contains('انتهت مهلة');
  }

  @override
  Future<UserModel?> getCurrentUser() async {
    final localSession = await _sessionDao.get();
    // أولوية لجلسة Supabase الحقيقية ثم الجلسة المحفوظة محلياً
    String? uid;
    try {
      uid = _remoteDatasource.currentUid ?? localSession?['user_id'] as String?;
    } catch (_) {
      uid = localSession?['user_id'] as String?;
    }
    if (uid == null || uid.isEmpty) return null;

    // محاولة جلب البيانات الحديثة من السحابة
    final remote = await fetchUserById(uid);
    if (remote != null) {
      try {
        await _sessionDao.saveUserJson(jsonEncode(remote.toJson()));
      } catch (_) {}
      return remote;
    }

    // لا يوجد إنترنت → استخدم النسخة المخزنة محلياً
    final cached = _sessionDao.getCachedUser(localSession);
    if (cached != null) {
      try {
        return UserModel.fromJson(cached);
      } catch (_) {}
    }
    return null;
  }

  @override
  Future<UserModel?> fetchUserById(String uid) async {
    try {
      final response = await _remoteDatasource.getUserById(uid)
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      if (response == null) return null;
      return UserModel.fromJson(response);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> hasActiveSession() {
    return _sessionDao.hasSession();
  }

  @override
  Future<void> logout() async {
    await _sessionDao.clear();
    await _remoteDatasource.logout();
  }
}
