import 'package:core/core.dart';

/// واجهة مستودع المصادقة
abstract class AuthRepository {
  /// تسجيل الدخول بالهاتف + PIN
  Future<LoginResult> login({
    required String phone,
    required String pin,
    bool rememberMe = false,
  });

  /// هل يوجد سوبر أدمن في النظام؟ (يُفحص قبل عرض شاشة تسجيل الدخول)
  Future<bool?> hasSystemAdmin();

  /// إنشاء أول سوبر أدمن (مزرعة + مدير النظام) — التشغيل الأول فقط
  Future<LoginResult> createFirstAdmin({
    required String farmName,
    String? location,
    required String managerName,
    required String phone,
    required String pin,
  });

  /// جلب المستخدم الحالي من الجلسة المحلية
  Future<UserModel?> getCurrentUser();

  /// هل توجد جلسة نشطة؟
  Future<bool> hasActiveSession();

  /// استرجاع بيانات المستخدم الكاملة من السحابة
  Future<UserModel?> fetchUserById(String uid);

  /// تسجيل الخروج
  Future<void> logout();
}

/// نتيجة تسجيل الدخول
class LoginResult {
  final bool success;
  final UserModel? user;
  final String? error;

  const LoginResult._({this.success = false, this.user, this.error});

  const LoginResult.success(UserModel user)
      : this._(success: true, user: user);
  const LoginResult.failure(String error) : this._(error: error);
}