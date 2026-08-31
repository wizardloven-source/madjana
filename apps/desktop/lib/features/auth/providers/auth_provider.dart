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

  AuthNotifier(this._repository) : super(const AuthState()) {
    _restoreSession();
  }

  /// استرجاع الجلسة المحفوظة عند فتح التطبيق
  Future<void> _restoreSession() async {
    final hasSession = await _repository.hasActiveSession();
    if (!hasSession) return;

    state = state.copyWith(isLoading: true);
    final user = await _repository.getCurrentUser();
    state = user != null
        ? AuthState(currentUser: user)
        : const AuthState(error: 'انتهت الجلسة، سجّل الدخول مجدداً');
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