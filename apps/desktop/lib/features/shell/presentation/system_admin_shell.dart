import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';
import '../../users/presentation/users_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../sync/presentation/sync_center_screen.dart';

/// [Shell] للنظام — يرى كل المداجن ويستطيع الدخول إلى أي مدجنة
class SystemAdminShell extends ConsumerStatefulWidget {
  const SystemAdminShell({super.key});

  @override
  ConsumerState<SystemAdminShell> createState() => _SystemAdminShellState();
}

class _SystemAdminShellState extends ConsumerState<SystemAdminShell> {
  String? _selectedFarmId;
  String? _selectedFarmName;
  int _farmsVersion = 0;
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
      // system_admin لا ي sync بشكل تلقائي — المزامنة عبر المديرين
    });
  }

  void _refreshFarms() {
    setState(() => _farmsVersion++);
  }

  void _pushScreen(Widget child, String title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          appBar: AppBar(
            backgroundColor: Theme.of(context).colorScheme.surface,
            elevation: 0,
            leading: const BackButton(),
            title: Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          body: child,
        ),
      ),
    );
  }

  Future<void> _addFarm() async {
    final created = await showDialog<FarmModel>(
      context: context,
      builder: (_) => const _AddFarmDialog(),
    );
    if (created == null || !mounted) return;

    _refreshFarms();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تم إنشاء المدجنة "${created.name}" مع مديرها')),
    );
    setState(() {
      _selectedFarmId = created.id;
      _selectedFarmName = created.name;
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
            width: 270,
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
                    fontSize: 15,
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
                  child: Row(
                    children: [
                      Text(
                        'المداجن',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'إضافة مدجنة',
                        iconSize: 20,
                        icon: Icon(
                          Icons.add_circle_outline_rounded,
                          color: theme.colorScheme.error,
                        ),
                        onPressed: _addFarm,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: KeyedSubtree(
                    key: ValueKey(_farmsVersion),
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
                ),

                const Divider(indent: 20, endIndent: 20),
                // المستخدمون + الإعدادات
                _ShellTile(
                  icon: Icons.people_rounded,
                  label: 'المستخدمون',
                  onTap: () =>
                      _pushScreen(const UsersScreen(), 'المستخدمون'),
                ),
                _ShellTile(
                  icon: Icons.sync_rounded,
                  label: 'مركز المزامنة',
                  onTap: () {
                    // SyncCenterScreen يملك AppBar الخاص به (يعرض زر الرجوع تلقائياً)
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const SyncCenterScreen()),
                    );
                  },
                ),
                _ShellTile(
                  icon: Icons.settings_rounded,
                  label: 'الإعدادات',
                  onTap: () => _pushScreen(const SettingsScreen(), 'الإعدادات'),
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
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'مدير النظام',
                        style: TextStyle(
                          fontSize: 11,
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
                      FilledButton.icon(
                        onPressed: _addFarm,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('إضافة مدجنة'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      const SizedBox(width: 12),
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
                  child: KeyedSubtree(
                    key: ValueKey(_farmsVersion),
                    child: _selectedFarmId == null
                        ? _AllFarmsOverview(onAddFarm: _addFarm)
                        : _FarmDetailView(
                            farmId: _selectedFarmId!,
                            farmName: _selectedFarmName ?? '',
                            onBack: () => setState(() {
                              _selectedFarmId = null;
                              _selectedFarmName = null;
                            }),
                          ),
                  ),
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
            child: Text('لا توجد مداجن', style: TextStyle(fontSize: 13)),
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
                        horizontal: 12, vertical: 11),
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
                                  fontSize: 13,
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
                                    fontSize: 11,
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
  final VoidCallback onAddFarm;
  const _AllFarmsOverview({required this.onAddFarm});

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
              Row(
                children: [
                  Text(
                    'نظرة عامة على ${farms.length} مدجنة',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onAddFarm,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('إضافة مدجنة'),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'اختر مدجنة من القائمة الجانبية لعرض بياناتها أو إنشاؤها',
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: farms.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.pets_rounded,
                                size: 56,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.2)),
                            const SizedBox(height: 12),
                            const Text('لا توجد مداجن بعد',
                                style: TextStyle(fontSize: 15)),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              onPressed: onAddFarm,
                              icon: const Icon(Icons.add_rounded),
                              label: const Text('إضافة المدجنة الأولى'),
                            ),
                          ],
                        ),
                      )
                    : GridView.builder(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: 2.4,
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
                                  if (farm.location != null &&
                                      farm.location!.isNotEmpty)
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

/// عرض تفاصيل مدجنة محددة
class _FarmDetailView extends ConsumerWidget {
  final String farmId;
  final String farmName;
  final VoidCallback onBack;
  const _FarmDetailView({
    required this.farmId,
    required this.farmName,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return FutureBuilder<FarmModel?>(
      future: _fetchFarm(ref),
      builder: (context, snapshot) {
        final farm = snapshot.data;
        final name = farm?.name ?? farmName;
        final location = farm?.location;

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'رجوع',
                    icon: const Icon(Icons.arrow_forward_rounded),
                    onPressed: onBack,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                location != null && location.isNotEmpty
                    ? 'الموقع: $location'
                    : 'لا يوجد موقع مسجل',
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 24),
              // بطاقات معلومات المدجنة
              Row(
                children: [
                  _InfoCard(
                    icon: Icons.tag_rounded,
                    label: 'معرّف المدجنة',
                    value: farmId,
                  ),
                  const SizedBox(width: 12),
                  _InfoCard(
                    icon: Icons.architecture_rounded,
                    label: 'الحالة',
                    value: 'نشطة',
                  ),
                  const SizedBox(width: 12),
                  _InfoCard(
                    icon: Icons.account_tree_outlined,
                    label: 'الإدارة',
                    value: 'مدير النظام',
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 28,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'إدارة هذه المدجنة',
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'يدخل مدير المدجنة عبر التطبيق (سطح المكتب أو الموبايل) '
                              'باستخدام رقم الهاتف والرمز السري الخاصين به. '
                              'يمكنك إنشاء المستخدمين وإدارة إعدادات المدجنة من '
                              'شاشة المستخدمين.',
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<FarmModel?> _fetchFarm(WidgetRef ref) async {
    try {
      final farms = await ref.read(userAdminRepositoryProvider).getAllFarms();
      for (final f in farms) {
        if (f.id == farmId) return f;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, size: 22, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700),
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
    );
  }
}

/// حوار إنشاء مدجنة جديدة مع مديرها (system_admin)
class _AddFarmDialog extends ConsumerStatefulWidget {
  const _AddFarmDialog();

  @override
  ConsumerState<_AddFarmDialog> createState() => _AddFarmDialogState();
}

class _AddFarmDialogState extends ConsumerState<_AddFarmDialog> {
  final _farmCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _managerNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _farmCtrl.dispose();
    _locationCtrl.dispose();
    _managerNameCtrl.dispose();
    _phoneCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  String _normalizeDigits(String input) {
    const arabic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    const persian = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
    final buffer = StringBuffer();
    for (final ch in input.runes) {
      final s = String.fromCharCode(ch);
      final ai = arabic.indexOf(s);
      if (ai >= 0) {
        buffer.write(ai);
        continue;
      }
      final pi = persian.indexOf(s);
      if (pi >= 0) {
        buffer.write(pi);
        continue;
      }
      buffer.write(s);
    }
    return buffer.toString().replaceAll(RegExp(r'[\s\-–]'), '');
  }

  Future<void> _submit() async {
    final farmName = _farmCtrl.text.trim();
    final location = _locationCtrl.text.trim();
    final managerName = _managerNameCtrl.text.trim();
    final phone = _normalizeDigits(_phoneCtrl.text);
    final pin = _normalizeDigits(_pinCtrl.text);

    if (farmName.isEmpty || managerName.isEmpty) {
      setState(() => _error = 'أدخل اسم المدجنة واسم المدير');
      return;
    }
    if (phone.isEmpty) {
      setState(() => _error = 'أدخل رقم هاتف المدير');
      return;
    }
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      setState(() => _error = 'الرمز السري يجب أن يكون 4 أرقام');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final created = await ref.read(userAdminRepositoryProvider).createFarmWithManager(
            farmName: farmName,
            location: location,
            managerName: managerName,
            phone: phone,
            pin: pin,
          );
      if (!mounted) return;
      Navigator.of(context).pop(created);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.add_business_rounded),
          SizedBox(width: 8),
          Text('إضافة مدجنة جديدة'),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _farmCtrl,
                decoration: const InputDecoration(
                  labelText: 'اسم المدجنة',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _locationCtrl,
                decoration: const InputDecoration(
                  labelText: 'الموقع (اختياري)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              const Divider(),
              Text(
                'بيانات المدير',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _managerNameCtrl,
                decoration: const InputDecoration(
                  labelText: 'اسم المدير',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'رقم الهاتف',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pinCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                decoration: const InputDecoration(
                  labelText: 'الرمز السري (4 أرقام)',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded),
          label: const Text('إنشاء المدجنة'),
        ),
      ],
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
          fontSize: 13,
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