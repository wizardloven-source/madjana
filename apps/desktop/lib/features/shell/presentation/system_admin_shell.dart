import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';
import '../../users/presentation/users_screen.dart';
import '../../settings/presentation/settings_screen.dart';

///.shell للنظام — يرى كل المداجن ويستطيع الدخول إلى أي مدجنة
class SystemAdminShell extends ConsumerStatefulWidget {
  const SystemAdminShell({super.key});

  @override
  ConsumerState<SystemAdminShell> createState() => _SystemAdminShellState();
}

class _SystemAdminShellState extends ConsumerState<SystemAdminShell> {
  String? _selectedFarmId;
  String? _selectedFarmName;
  Timer? _syncTimer;

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

  void _startPeriodicSync() {
    _syncTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      // system_admin لا ي zsinc بشكل تلقائي — المزامنة عبر المديرين
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider.select((s) => s.currentUser));
    final theme = Theme.of(context);

    return Scaffold(
      body: Row(
        children: [
          // شريط جانبي
          Container(
            width: 260,
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
                const SizedBox(height: 20),
                // شعار النظام
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        theme.colorScheme.error,
                        theme.colorScheme.errorContainer,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.admin_panel_settings_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'نظام الإدارة',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(indent: 20, endIndent: 20),
                const SizedBox(height: 8),

                // المداجن
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'المداجن',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: _FarmList(
                    selectedFarmId: _selectedFarmId,
                    onFarmSelected: (farmId, farmName) {
                      setState(() {
                        _selectedFarmId = farmId;
                        _selectedFarmName = farmName;
                      });
                    },
                  ),
                ),

                const Divider(indent: 20, endIndent: 20),
                // المستخدمون + الإعدادات
                _ShellTile(
                  icon: Icons.people_rounded,
                  label: 'المستخدمون',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const UsersScreen()),
                    );
                  },
                ),
                _ShellTile(
                  icon: Icons.settings_rounded,
                  label: 'الإعدادات',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    );
                  },
                ),
                const SizedBox(height: 8),
                // معلومات المستخدم
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: theme.colorScheme.errorContainer,
                        child: Icon(Icons.admin_panel_settings_rounded,
                            size: 20, color: theme.colorScheme.error),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        user?.name ?? '',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'مدير النظام',
                        style: TextStyle(
                          fontSize: 10,
                          color: theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 6),
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
                // شريط علوي
                Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    border: Border(
                      bottom: BorderSide(
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        _selectedFarmName ?? 'نظرة عامة على جميع المداجن',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.admin_panel_settings_rounded,
                                size: 14,
                                color: theme.colorScheme.error),
                            const SizedBox(width: 4),
                            Text(
                              'مدير النظام',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // محتوى
                Expanded(
                  child: _selectedFarmId == null
                      ? const _AllFarmsOverview()
                      : _FarmDetailView(farmId: _selectedFarmId!),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// قائمة المداجن في الشريط الجانبي
class _FarmList extends ConsumerWidget {
  final String? selectedFarmId;
  final void Function(String farmId, String farmName) onFarmSelected;

  const _FarmList({
    required this.selectedFarmId,
    required this.onFarmSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return FutureBuilder<List<FarmModel>>(
      future: _fetchAllFarms(ref),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final farms = snapshot.data ?? [];
        if (farms.isEmpty) {
          return const Center(
            child: Text('لا توجد مداجن', style: TextStyle(fontSize: 12)),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: farms.length,
          itemBuilder: (context, i) {
            final farm = farms[i];
            final isSelected = selectedFarmId == farm.id;
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Material(
                color: isSelected
                    ? theme.colorScheme.errorContainer.withValues(alpha: 0.3)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onFarmSelected(farm.id, farm.name),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        Icon(
                          Icons.pets_rounded,
                          size: 18,
                          color: isSelected
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                farm.name,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: isSelected
                                      ? theme.colorScheme.error
                                      : theme.colorScheme.onSurface,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (farm.location != null &&
                                  farm.location!.isNotEmpty)
                                Text(
                                  farm.location!,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.5),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<List<FarmModel>> _fetchAllFarms(WidgetRef ref) async {
    try {
      final repo = ref.read(userAdminRepositoryProvider);
      return await repo.getAllFarms();
    } catch (_) {
      return [];
    }
  }
}

/// نظرة عامة على جميع المداجن
class _AllFarmsOverview extends ConsumerWidget {
  const _AllFarmsOverview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return FutureBuilder<List<FarmModel>>(
      future: _fetchAllFarms(ref),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final farms = snapshot.data ?? [];

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'نظرة عامة على ${farms.length} مدجنة',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 2.2,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: farms.length,
                  itemBuilder: (context, i) {
                    final farm = farms[i];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.pets_rounded,
                                    size: 20,
                                    color: theme.colorScheme.primary),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    farm.name,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (farm.location != null)
                              Text(
                                farm.location!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<List<FarmModel>> _fetchAllFarms(WidgetRef ref) async {
    try {
      final repo = ref.read(userAdminRepositoryProvider);
      return await repo.getAllFarms();
    } catch (_) {
      return [];
    }
  }
}

/// عرض تفاصيل مدجنة محددة (مختصر)
class _FarmDetailView extends StatelessWidget {
  final String farmId;
  const _FarmDetailView({required this.farmId});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.pets_rounded, size: 64, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(
            'عرض بيانات المدجنة',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'معرّف المدجنة: $farmId',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'يمكنك إدارة بيانات هذه المدجنة من لوحة التحكم',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShellTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ShellTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, size: 20, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurface,
        ),
      ),
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      onTap: onTap,
    );
  }
}
