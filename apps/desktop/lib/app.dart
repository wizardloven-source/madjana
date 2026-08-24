import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'core/theme.dart';
import 'features/auth/presentation/login_screen.dart';
import 'features/auth/providers/auth_provider.dart';
import 'features/shell/presentation/manager_shell.dart';

/// التطبيق الرئيسي لتطبيق سطح المكتب (للمدير)
class MadjanaDesktopApp extends ConsumerWidget {
  const MadjanaDesktopApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);

    final Widget home;
    if (!authState.isLoggedIn) {
      home = const LoginScreen();
    } else if (authState.currentUser!.role != UserRole.manager) {
      home = const _NotAuthorizedScreen();
    } else {
      home = const ManagerShell();
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