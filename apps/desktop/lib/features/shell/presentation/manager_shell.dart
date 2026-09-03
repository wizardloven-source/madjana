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
        // رفع المصروفات المحفوظة محلياً أثناء الانقطاع (المدير فقط)
        try {
          await ref.read(expenseRepositoryProvider).syncPendingRecords();
        } catch (_) {}

        final pulled = await ref.read(syncRepositoryProvider).syncNow(farmId);
        if (pulled.uploadedCount > 0 || pulled.downloadedCount > 0 && mounted) {
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
          // NavigationRail محسّن — عرض ERP (230px) مع نص واضح ≥13px
          Container(
            width: 230,
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
                // شعار التطبيق + الاسم
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
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
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'مداجن',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(indent: 16, endIndent: 16),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    itemCount: _icons.length,
                    itemBuilder: (context, i) {
                      final isSelected = selectedIndex == i;
                      return _NavTile(
                        icon: _icons[i],
                        label: _titles[i],
                        selected: isSelected,
                        badgeCount: i == 6 ? pendingApprovals : 0,
                        onTap: () => ref
                            .read(shellTabProvider.notifier)
                            .state = i,
                      );
                    },
                  ),
                ),
                const Divider(indent: 16, endIndent: 16),
                // معلومات المستخدم
                Padding(
                  padding: const EdgeInsets.all(12),
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
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'مدير',
                        style: TextStyle(
                          fontSize: 12,
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

/// عنصر تنقّل ERP أفقي: أيقونة + نص واضح (≥13px)
class _NavTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final int badgeCount;
  final VoidCallback onTap;

  const _NavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.badgeCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            height: 44,
            alignment: Alignment.center,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 8),
                    Icon(
                      icon,
                      size: 20,
                      color: selected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface.withValues(alpha: 0.65),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface.withValues(alpha: 0.75),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
                if (badgeCount > 0)
                  Positioned(
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                      child: Text(
                        '$badgeCount',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
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
  }
}
