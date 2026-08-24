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

  AuthState copyWith({
    UserModel? currentUser,
    bool? isLoading,
    String? error,
  }) {
    return AuthState(
      currentUser: currentUser ?? this.currentUser,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
    );
  }
}

/// Provider للمصادقة
class AuthNotifier extends StateNotifier<AuthState> {
  final AuthRepository _repository;

  AuthNotifier(this._repository)
      : super(const AuthState(isLoading: true)) {
    _restoreSession();
  }

  /// استرجاع الجلسة المحفوظة عند فتح التطبيق
  Future<void> _restoreSession() async {
    try {
      final hasSession = await _repository.hasActiveSession();
      if (!hasSession) {
        // لا توجد جلسة محفوظة → شاشة تسجيل الدخول مباشرة
        state = const AuthState();
        return;
      }

      final user = await _repository.getCurrentUser();
      state = user != null
          ? AuthState(currentUser: user)
          : const AuthState(error: 'انتهت الجلسة، سجّل الدخول مجدداً');
    } catch (_) {
      // أي خطأ أثناء الاسترجاع يجب ألا يعلّق شاشة الانتظار
      state = const AuthState(error: 'تعذر استرجاع الجلسة، سجّل الدخول');
    }
  }

  /// تسجيل الدخول
  Future<LoginResult> login({
    required String phone,
    required String pin,
    bool rememberMe = false,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    final result = await _repository.login(
      phone: phone,
      pin: pin,
      rememberMe: rememberMe,
    );

    if (result.success) {
      state = AuthState(currentUser: result.user);
    } else {
      state = state.copyWith(
        isLoading: false,
        error: result.error,
      );
    }

    return result;
  }

  /// تسجيل الخروج
  Future<void> logout() async {
    await _repository.logout();
    state = const AuthState();
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(ref.watch(authRepositoryProvider)),
);