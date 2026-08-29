import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers.dart';
import '../../../core/shell_state.dart';
import '../../approvals/presentation/approvals_screen.dart';
import '../../auth/providers/auth_provider.dart';
import '../../dashboard/presentation/dashboard_screen.dart';
import '../../dispatch/presentation/dispatch_screen.dart';
import '../../egg_production/presentation/egg_production_screen.dart';
import '../../expenses/presentation/expenses_screen.dart';
import '../../feed/presentation/feed_screen.dart';
import '../../flocks/presentation/flocks_screen.dart';
import '../../inventory/presentation/inventory_screen.dart';
import '../../mortality/presentation/mortality_screen.dart';
import '../../notifications/presentation/notifications_screen.dart';
import '../../medicines/presentation/medicines_screen.dart';
import '../../reports/presentation/reports_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../users/presentation/users_screen.dart';
import '../../customers/presentation/customers_screen.dart';

class ManagerShell extends ConsumerStatefulWidget {
  const ManagerShell({super.key});

  @override
  ConsumerState<ManagerShell> createState() => _ManagerShellState();
}

class _ManagerShellState extends ConsumerState<ManagerShell> {
  final _screens = const [
    DashboardScreen(),
    FlocksScreen(),
    EggProductionScreen(),
    MortalityScreen(),
    FeedScreen(),
    DispatchScreen(),
    ApprovalsScreen(),
    NotificationsScreen(),
    ExpensesScreen(),
    InventoryScreen(),
    ReportsScreen(),
    MedicinesScreen(),
    CustomersScreen(),
    UsersScreen(),
    SettingsScreen(),
  ];

  static const _titles = [
    'لوحة التحكم',
    'القطعان',
    'إنتاج البيض',
    'النفوق',
    'العلف',
    'التخريج والقبض',
    'طلبات الموافقة',
    'الإشعارات',
    'المصروفات',
    'المخزون',
    'التقارير',
    'الأدوية',
    'الزبائن',
    'المستخدمون',
    'الإعدادات',
  ];

  static const _icons = [
    Icons.dashboard_rounded,
    Icons.pets_rounded,
    Icons.egg_alt_rounded,
    Icons.heart_broken_rounded,
    Icons.grass_rounded,
    Icons.local_shipping_rounded,
    Icons.approval_rounded,
    Icons.campaign_rounded,
    Icons.receipt_long_rounded,
    Icons.inventory_rounded,
    Icons.insert_chart_rounded,
    Icons.medical_services_rounded,
    Icons.group_rounded,
    Icons.people_rounded,
    Icons.settings_rounded,
  ];

  @override
  void initState() {
    super.initState();
    _startPeriodicSync();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }

  /// مزامنة دورية: رفع المعلّق + سحب سجلات الأجهزة الأخرى كل 30 ثانية
  /// (توازي المحرك التلقائي في الموبايل).
  Timer? _syncTimer;
  void _startPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final farmId = ref.read(authProvider).currentUser?.farmId ?? '';
      if (farmId.isEmpty) return;
      try {
        final pulled = await ref.read(syncRepositoryProvider).syncNow(farmId);
        if (pulled > 0 && mounted) {
          ref.read(dataRefreshTickProvider.notifier).state++;
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider.select((s) => s.currentUser));
    final selectedIndex = ref.watch(shellTabProvider);
    final pendingApprovals = ref.watch(pendingApprovalsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: Row(
        children: [
          // NavigationRail محسّن
          Container(
            width: 80,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                left: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: 12),
                // شعار التطبيق
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        theme.colorScheme.primary,
                        theme.colorScheme.tertiary,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.egg_alt_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'مداجن',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(indent: 16, endIndent: 16),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    itemCount: _icons.length,
                    itemBuilder: (context, i) {
                      final isSelected = selectedIndex == i;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Material(
                          color: isSelected
                              ? theme.colorScheme.primaryContainer
                                  .withValues(alpha: 0.4)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => ref
                                .read(shellTabProvider.notifier)
                                .state = i,
                            child: SizedBox(
                              height: 52,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _icons[i],
                                        size: 22,
                                        color: isSelected
                                            ? theme.colorScheme.primary
                                            : theme.colorScheme.onSurface
                                                .withValues(alpha: 0.6),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _titles[i],
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: isSelected
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: isSelected
                                              ? theme.colorScheme.primary
                                              : theme.colorScheme.onSurface
                                                  .withValues(alpha: 0.6),
                                        ),
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                  if (i == 6 && pendingApprovals > 0)
                                    Positioned(
                                      top: 4,
                                      left: 8,
                                      child: Container(
                                        padding: const EdgeInsets.all(3),
                                        decoration: const BoxDecoration(
                                          color: Colors.red,
                                          shape: BoxShape.circle,
                                        ),
                                        constraints: const BoxConstraints(
                                            minWidth: 14, minHeight: 14),
                                        child: Text(
                                          '$pendingApprovals',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 8,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const Divider(indent: 16, endIndent: 16),
                // معلومات المستخدم
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor:
                            theme.colorScheme.primaryContainer,
                        child: Icon(Icons.person_rounded,
                            size: 18, color: theme.colorScheme.primary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        user?.name ?? '',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'مدير',
                        style: TextStyle(
                          fontSize: 9,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: double.infinity,
                        child: IconButton(
                          tooltip: 'تسجيل الخروج',
                          icon: Icon(Icons.logout_rounded,
                              size: 18,
                              color: theme.colorScheme.error),
                          onPressed: () =>
                              ref.read(authProvider.notifier).logout(),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),

          // المحتوى الرئيسي
          Expanded(
            child: Column(
              children: [
                // شريط علوي مخصص
                Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    border: Border(
                      bottom: BorderSide(
                        color: theme.colorScheme.outlineVariant
                            .withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        _titles[selectedIndex],
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const Spacer(),
                      // شعار مداجن
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.egg_alt_rounded,
                                size: 14,
                                color: theme.colorScheme.primary),
                            const SizedBox(width: 4),
                            Text(
                              'مداجن',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // محتوى الشاشة
                Expanded(child: _screens[selectedIndex]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
