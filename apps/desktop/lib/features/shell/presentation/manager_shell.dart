import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import '../../reports/presentation/reports_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../users/presentation/users_screen.dart';

/// الهيكل الرئيسي للمدير (NavigationRail + صفحات)
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
    'المستخدمون',
    'الإعدادات',
  ];

  static const _icons = [
    Icons.dashboard_outlined,
    Icons.pets_outlined,
    Icons.egg_alt_outlined,
    Icons.heart_broken_outlined,
    Icons.grass_outlined,
    Icons.local_shipping_outlined,
    Icons.approval_outlined,
    Icons.campaign_outlined,
    Icons.receipt_long_outlined,
    Icons.inventory_outlined,
    Icons.insert_chart_outlined,
    Icons.people_outline,
    Icons.settings_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider.select((s) => s.currentUser));
    final selectedIndex = ref.watch(shellTabProvider);
    final pendingApprovals = ref.watch(pendingApprovalsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[selectedIndex]),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Text(
                '${user?.name ?? ''} - مدير',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          IconButton(
            tooltip: 'تسجيل الخروج',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authProvider.notifier).logout(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: selectedIndex,
            onDestinationSelected: (i) =>
                ref.read(shellTabProvider.notifier).state = i,
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (var i = 0; i < _icons.length; i++)
                NavigationRailDestination(
                  icon: _railIcon(i, pendingApprovals),
                  label: Text(_titles[i]),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _screens[selectedIndex]),
        ],
      ),
    );
  }

  /// أيقونة الشريط مع شارة عدد طلبات الموافقة المعلقة
  Widget _railIcon(int index, int pendingApprovals) {
    final icon = Icon(_icons[index]);

    if (index != 6 || pendingApprovals <= 0) return icon;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: -6,
          top: -4,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: const BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
            ),
            constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
            child: Text(
              '$pendingApprovals',
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
    );
  }
}