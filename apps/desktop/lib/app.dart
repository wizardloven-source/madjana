import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'core/theme.dart';
import 'core/theme_provider.dart';
import 'features/auth/presentation/bootstrap_admin_screen.dart';
import 'features/auth/presentation/login_screen.dart';
import 'features/auth/providers/auth_provider.dart';
import 'features/shell/presentation/manager_shell.dart';
import 'features/shell/presentation/system_admin_shell.dart';

/// التطبيق الرئيسي لتطبيق سطح المكتب (للمدير)
class MadjanaDesktopApp extends ConsumerWidget {
  const MadjanaDesktopApp({super.key, this.startupBlockMessage});

  /// رسالة حظر الإقلاع عند تعارض إصدار المخطط (M9 — docs/SYNC.md).
  /// عندما تكون غير null تُعرض شاشة حجب كاملة بدل الواجهة.
  final String? startupBlockMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // بوابة الإصدار لها الأولوية: لا نفتح أي شيء قبل حل التعارض.
    final blockMessage = startupBlockMessage;
    if (blockMessage != null) {
      return MaterialApp(
        title: 'YAseen Farm',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme(),
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: _StartupBlockScreen(message: blockMessage),
      );
    }

    final authState = ref.watch(authProvider);
    final themeMode = ref.watch(themeModeProvider);

    final Widget home;
    if (authState.isLoggedIn) {
      home = _authenticatedHome(authState.currentUser!);
    } else {
      home = const _UnauthenticatedGate();
    }

    return MaterialApp(
      title: 'YAseen Farm',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: themeMode,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    );
  }

  Widget _authenticatedHome(UserModel user) {
    switch (user.role) {
      case UserRole.system_admin:
        return const SystemAdminShell();
      case UserRole.manager:
        return const ManagerShell();
      default:
        return const _NotAuthorizedScreen();
    }
  }
}

/// بوابة الدخول قبل تسجيل الدخول:
/// إن لم يوجد سوبر أدمن في النظام → شاشة إنشاء الحساب الأول،
/// وإلا → شاشة تسجيل الدخول العادية.
class _UnauthenticatedGate extends ConsumerStatefulWidget {
  const _UnauthenticatedGate();

  @override
  ConsumerState<_UnauthenticatedGate> createState() => _UnauthenticatedGateState();
}

class _UnauthenticatedGateState extends ConsumerState<_UnauthenticatedGate> {
  /// عند كسر التحقق (مثلاً بروفايل سوبر أدمن محذوف) يسمح بالانتقال
  /// يدوياً إلى شاشة تسجيل الدخول.
  bool _forceLogin = false;

  @override
  void initState() {
    super.initState();
    // إعادة فحص التهيئة عند كل فتح لشاشة الدخول
    // (مثلاً بعد إنشاء الحساب الأول ثم تسجيل الخروج — لا نعرض الشاشة مجدداً)
    Future.microtask(() {
      if (mounted) ref.invalidate(needsBootstrapProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_forceLogin) return const LoginScreen();
    final needsBootstrap = ref.watch(needsBootstrapProvider);

    return needsBootstrap.when(
      loading: () => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.egg_alt, size: 64),
              const SizedBox(height: 16),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ],
          ),
        ),
      ),
      error: (_, __) => const LoginScreen(),
      data: (needsBootstrap) => needsBootstrap == true
          ? BootstrapAdminScreen(
              onBackToLogin: () => setState(() => _forceLogin = true),
            )
          : const LoginScreen(),
    );
  }
}

/// شاشة حجب الإقلاع — تعارض إصدار المخطط بين التطبيق والخادم.
/// لا تُمكّن التفاعل؛ المستخدم يُحدِّث التطبيق أو ينتظر دعم الخادم.
class _StartupBlockScreen extends StatelessWidget {
  const _StartupBlockScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sync_problem, size: 64, color: Colors.orangeAccent),
              const SizedBox(height: 16),
              const Text(
                'توقف المزامنة — تعارض الإصدار',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

/// شاشة عدم الصلاحية (العامل لا يصل للمدير أبداً)
class _NotAuthorizedScreen extends ConsumerWidget {
  const _NotAuthorizedScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 64, color: Colors.redAccent),
            const SizedBox(height: 16),
            const Text(
              'هذا التطبيق مخصص للمدير فقط',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text('حساب العامل لا يملك صلاحية الوصول للبيانات المالية'),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => ref.read(authProvider.notifier).logout(),
              icon: const Icon(Icons.logout),
              label: const Text('تسجيل الخروج'),
            ),
          ],
        ),
      ),
    );
  }
}