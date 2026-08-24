import 'dart:convert';

import 'package:core/core.dart';
import 'package:domain/domain.dart';
import '../datasources/local/daos/session_dao.dart';
import '../datasources/remote/supabase_auth_datasource.dart';

/// تنفيذ مستودع المصادقة
class AuthRepositoryImpl implements AuthRepository {
  final SupabaseAuthDatasource _remoteDatasource;
  final SessionDao _sessionDao;

  AuthRepositoryImpl({
    required SupabaseAuthDatasource remoteDatasource,
    required SessionDao sessionDao,
  })  : _remoteDatasource = remoteDatasource,
        _sessionDao = sessionDao;

  @override
  Future<LoginResult> login({
    required String phone,
    required String pin,
    bool rememberMe = false,
  }) async {
    try {
      final user = await _remoteDatasource.login(phone: phone, pin: pin);

      // حفظ الجلسة محلياً مع بيانات المستخدم (للاسترجاع بدون إنترنت)
      await _sessionDao.save(
        userId: user.uid,
        farmId: user.farmId ?? '',
        rememberToken: rememberMe ? user.uid : null,
        userJson: jsonEncode(user.toJson()),
      );

      return LoginResult.success(user);
    } on AuthException catch (e) {
      return LoginResult.failure(e.message);
    } catch (e) {
      return LoginResult.failure('خطأ غير متوقع: $e');
    }
  }

  @override
  Future<UserModel?> getCurrentUser() async {
    final localSession = await _sessionDao.get();
    // أولوية لجلسة Supabase الحقيقية ثم الجلسة المحفوظة محلياً
    final uid =
        _remoteDatasource.currentUid ?? localSession?['user_id'] as String?;
    if (uid == null || uid.isEmpty) return null;

    // محاولة جلب البيانات الحديثة من السحابة
    final remote = await fetchUserById(uid);
    if (remote != null) {
      // تحديث النسخة المخزنة لأجل المرات القادمة بدون إنترنت
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
      final response = await _remoteDatasource.getUserById(uid);
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
