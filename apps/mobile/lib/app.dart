import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme.dart';
import 'features/auth/presentation/login_screen.dart';
import 'features/auth/providers/auth_provider.dart';
import 'features/dispatch/presentation/dispatch_screen.dart';
import 'features/egg_production/presentation/egg_production_screen.dart';
import 'features/feed_consumption/presentation/feed_consumption_screen.dart';
import 'features/feed_received/presentation/feed_received_screen.dart';
import 'features/home/presentation/home_screen.dart';
import 'features/medications/presentation/medications_screen.dart';
import 'features/mortality/presentation/mortality_screen.dart';
import 'features/notes/presentation/notes_screen.dart';
import 'features/notifications/presentation/notifications_screen.dart';
import 'features/payments/presentation/payments_screen.dart';
import 'features/reports/presentation/reports_screen.dart';
import 'features/settings/presentation/settings_screen.dart';
import 'features/settings/providers/theme_provider.dart';

/// التطبيق الرئيسي
class PoultryApp extends ConsumerWidget {
  const PoultryApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDarkMode = ref.watch(themeProvider);

    return MaterialApp(
      title: 'نظام إدارة المداجن',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: isDarkMode ? ThemeMode.dark : ThemeMode.light,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // بوابة الجذر: شاشة انتظار أثناء استرجاع الجلسة ثم التوجيه
      home: const _RootGate(),
      routes: {
        '/login': (_) => const LoginScreen(),
        '/home': (_) => const HomeScreen(),
        '/notes': (_) => const NotesScreen(),
        '/notifications': (_) => const NotificationsScreen(),
        '/egg-production': (_) => const EggProductionScreen(),
        '/mortality': (_) => const MortalityScreen(),
        '/feed-consumption': (_) => const FeedConsumptionScreen(),
        '/dispatch': (_) => const DispatchScreen(),
        '/medications': (_) => const MedicationsScreen(),
        '/feed-received': (_) => const FeedReceivedScreen(),
        '/settings': (_) => const SettingsScreen(),
        '/payments': (_) => const PaymentsScreen(),
        '/reports': (_) => const ReportsScreen(),
      },
    );
  }
}

/// يقرر الشاشة الأولى حسب حالة المصادقة
/// - أثناء استرجاع الجلسة المحفوظة → شاشة انتظار (بدون وميض تسجيل الدخول)
/// - جلسة صالحة (حتى بدون إنترنت) → الرئيسية مباشرة
/// - لا جلسة → تسجيل الدخول
class _RootGate extends ConsumerWidget {
  const _RootGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final theme = Theme.of(context);

    if (authState.isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                ),
                child: Icon(
                  Icons.egg,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'نظام إدارة المداجن',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 32),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ],
          ),
        ),
      );
    }

    if (authState.isLoggedIn) {
      return const HomeScreen();
    }
    return const LoginScreen();
  }
}
