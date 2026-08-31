import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// حالة المصادقة
class AuthState {
  final UserModel? currentUser;
  final bool isLoading;
  final String? error;

  const AuthState({
    this.currentUser,
    this.isLoading = false,
    this.error,
  });

  bool get isLoggedIn => currentUser != null;

  // علم مميز: يسمح لإفراغ الحقول nullable (كإزالة المستخدم)
  static const _unset = Object();

  AuthState copyWith({
    Object? currentUser = _unset,
    bool? isLoading,
    Object? error = _unset,
    bool clearError = false,
  }) {
    return AuthState(
      currentUser: identical(currentUser, _unset) ? this.currentUser : currentUser as UserModel?,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (identical(error, _unset) ? this.error : error as String?),
    );
  }
}

/// Provider للمصادقة
class AuthNotifier extends StateNotifier<AuthState> {
  final AuthRepository _repository;
  bool _sessionRestored = false;

  AuthNotifier(this._repository)
      : super(const AuthState(isLoading: true)) {
    _restoreSession();
  }

  /// استرجاع الجلسة المحفوظة عند فتح التطبيق
  Future<void> _restoreSession() async {
    try {
      final hasSession = await _repository.hasActiveSession()
          .timeout(const Duration(seconds: 3), onTimeout: () => false);
      if (!hasSession) {
        if (!_sessionRestored && mounted) {
          _sessionRestored = true;
          state = const AuthState();
        }
        return;
      }

      final user = await _repository.getCurrentUser()
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      if (!_sessionRestored && mounted) {
        _sessionRestored = true;
        state = user != null
            ? AuthState(currentUser: user)
            : const AuthState(error: 'انتهت الجلسة، سجّل الدخول مجدداً');
      }
    } catch (_) {
      if (!_sessionRestored && mounted) {
        _sessionRestored = true;
        state = const AuthState(error: 'تعذر استرجاع الجلسة، سجّل الدخول');
      }
    }
  }

  /// تسجيل الدخول
  Future<LoginResult> login({
    required String phone,
    required String pin,
    bool rememberMe = false,
  }) async {
    try {
      final result = await _repository.login(
        phone: phone,
        pin: pin,
        rememberMe: rememberMe,
      );

      if (!mounted) return result;

      if (result.success) {
        _sessionRestored = true;
        state = AuthState(currentUser: result.user);
      }
      // في حال الخطأ: لا نُغيّر الحالة هنا — الشاشة تُدير `_errorText` محلياً

      return result;
    } catch (e) {
      return LoginResult.failure('خطأ غير متوقع: $e');
    }
  }

  /// تسجيل الخروج
  Future<void> logout() async {
    try {
      await _repository.logout();
    } catch (_) {}
    _sessionRestored = false;
    if (mounted) {
      state = const AuthState();
    }
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(ref.watch(authRepositoryProvider)),
);
