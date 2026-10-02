import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// حالة المصادقة
class AuthState {
  final UserModel? currentUser;
  final bool isLoading;
  final String? error;

  const AuthState({this.currentUser, this.isLoading = false, this.error});

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
      currentUser: identical(currentUser, _unset)
          ? this.currentUser
          : currentUser as UserModel?,
      isLoading: isLoading ?? this.isLoading,
      error: clearError
          ? null
          : (identical(error, _unset) ? this.error : error as String?),
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
      state = state.copyWith(isLoading: false, error: result.error);
    }

    return result;
  }

  /// إنشاء أول سوبر أدمن (التشغيل الأول فقط)
  Future<LoginResult> createFirstAdmin({
    required String farmName,
    String? location,
    required String managerName,
    required String phone,
    required String pin,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    final result = await _repository.createFirstAdmin(
      farmName: farmName,
      location: location,
      managerName: managerName,
      phone: phone,
      pin: pin,
    );

    if (result.success) {
      state = AuthState(currentUser: result.user);
    } else {
      state = state.copyWith(isLoading: false, error: result.error);
    }

    return result;
  }

  /// تحديد المدجنة النشطة للمستخدم الحالي (من قائمة مداجنه المرتبطة)
  ///
  /// State is only advanced after the server confirms. `set_active_farm`
  /// refuses any farm the user is not a member of, and this notifier used to
  /// update `currentUser` optimistically with the REQUESTED farm before
  /// knowing the outcome. The UI then showed a farm the user did not own
  /// while `users.farm_id` on the server was unchanged, and flocks were later
  /// found filed under it. Now we keep state untouched on rejection and
  /// return false.
  Future<bool> setActiveFarm(String farmId) async {
    final user = state.currentUser;
    if (user == null) return false;

    UserModel? updated;
    try {
      updated = await _repository.setActiveFarm(farmId);
    } catch (e) {
      debugPrint('setActiveFarm($farmId) failed: $e');
      return false;
    }
    if (updated == null) return false;

    // The server may answer with a different farm than requested, so we take
    // its value rather than the requested one.
    state = state.copyWith(
      currentUser: updated.copyWith(farmIds: user.farmIds),
    );
    return updated.farmId == farmId;
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

/// هل النظام بحاجة لتهيئة أولية (إنشاء أول سوبر أدمن)؟
/// القيم: null = قيد التحقق/شبكة معطلة، true = لا يوجد سوبر أدمن، false = موجود
final needsBootstrapProvider = FutureProvider<bool?>((ref) async {
  final repo = ref.watch(authRepositoryProvider);
  final hasAdmin = await repo.hasSystemAdmin();
  if (hasAdmin == null) return null;
  return !hasAdmin;
});
