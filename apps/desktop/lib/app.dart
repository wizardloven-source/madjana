import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'core/theme.dart';
import 'features/auth/presentation/bootstrap_admin_screen.dart';
import 'features/auth/presentation/login_screen.dart';
import 'features/auth/providers/auth_provider.dart';
import 'features/shell/presentation/manager_shell.dart';
import 'features/shell/presentation/system_admin_shell.dart';

/// التطبيق الرئيسي لتطبيق سطح المكتب (للمدير)
class MadjanaDesktopApp extends ConsumerWidget {
  const MadjanaDesktopApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);

    final Widget home;
    if (authState.isLoggedIn) {
      home = _authenticatedHome(authState.currentUser!);
    } else {
      home = const _UnauthenticatedGate();
    }

    return MaterialApp(
      title: 'نظام إدارة المداجن - سطح المكتب',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: ThemeMode.dark,
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
      data: (needsBootstrap) =>
          needsBootstrap == true ? const BootstrapAdminScreen() : const LoginScreen(),
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