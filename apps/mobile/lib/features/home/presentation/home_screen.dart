import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/design_tokens.dart';
import '../../auth/providers/auth_provider.dart';
import '../../notifications/providers/notifications_provider.dart';
import '../../sync/providers/sync_provider.dart';
import '../../../core/providers.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).currentUser;
    final syncState = ref.watch(syncProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final farmId = user.farmId;
    if (farmId != null && farmId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(syncProvider.notifier).setFarmId(farmId);
      });
    }

    final isManager = user.role == UserRole.manager || user.role == UserRole.system_admin;
    final pendingCount = syncState.pendingCount;
    final persistentNotices =
        ref.watch(activeNoticesProvider(user.farmId ?? '')).value ??
            const <AppNotificationModel>[];
    final persistentCount =
        persistentNotices.where((n) => n.isPersistent).length;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F1114) : const Color(0xFFF5F7FA),
      body: CustomScrollView(
        slivers: [
          // App Bar عصري
          SliverToBoxAdapter(
            child: Container(
              padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 8, 20, 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [
                    cs.primary,
                    cs.primary.withValues(alpha: 0.8),
                    cs.tertiary.withValues(alpha: 0.6),
                  ],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // صف علوي: إشعارات + مزامنة
                  Row(
                    children: [
                      const Spacer(),
                      _AppBarIcon(
                        icon: Icons.notifications_outlined,
                        badge: persistentCount,
                        onTap: () =>
                            Navigator.pushNamed(context, '/notifications'),
                      ),
                      const SizedBox(width: 8),
                      _AppBarIcon(
                        icon: syncState.isSyncing
                            ? Icons.sync_rounded
                            : Icons.cloud_upload_outlined,
                        badge: pendingCount,
                        isSpinning: syncState.isSyncing,
                        onTap: syncState.isSyncing
                            ? null
                            : () => ref
                                .read(syncProvider.notifier)
                                .syncNow(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // ترحيب
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        child: Icon(
                          isManager
                              ? Icons.admin_panel_settings_rounded
                              : Icons.person_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'مرحباً، ${user.name}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              user.role.label,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white.withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'تسجيل الخروج',
                        icon: Icon(Icons.logout_rounded,
                            color: Colors.white.withValues(alpha: 0.8)),
                        onPressed: () => _confirmLogout(context, ref),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.list(
              children: [
                // شريط المزامنة
                if (syncState.connectionStatus ==
                    SyncConnectionStatus.disconnected)
                  const OfflineBanner(),
                if (syncState.connectionStatus !=
                    SyncConnectionStatus.disconnected)
                  _SyncStatusBanner(
                    pendingCount: pendingCount,
                    failedCount: syncState.failedCount,
                    lastSyncAt: syncState.lastSyncAt,
                    isDark: isDark,
                  ),
                const SizedBox(height: 16),

                // ملخص اليوم + أزرار التسجيل الكبيرة
                if (farmId != null && farmId.isNotEmpty) ...[
                  _TodaySummaryCard(farmId: farmId),
                  const SizedBox(height: 12),
                ],
                _QuickActionsRow(isManager: isManager),
                const SizedBox(height: 16),

                // إشعارات المدير الدائمة
                if (persistentNotices.isNotEmpty) ...[
                  _PersistentNotices(farmId: user.farmId ?? ''),
                  const SizedBox(height: 16),
                ],

                // عنوان العمليات
                Text(
                  'العمليات السريعة',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),

          // شبكة العمليات
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.4,
              ),
              delegate: SliverChildListDelegate([
                _MenuCard(
                  icon: Icons.egg_rounded,
                  label: 'إدخال البيض',
                  color: cs.primary,
                  onTap: () =>
                      Navigator.pushNamed(context, '/egg-production'),
                ),
                _MenuCard(
                  icon: Icons.heart_broken_rounded,
                  label: 'إدخال النفوق',
                  color: AppStatusColors.danger(context),
                  onTap: () => Navigator.pushNamed(context, '/mortality'),
                ),
                _MenuCard(
                  icon: Icons.grain_rounded,
                  label: 'استهلاك العلف',
                  color: AppStatusColors.info(context),
                  onTap: () =>
                      Navigator.pushNamed(context, '/feed-consumption'),
                ),
                _MenuCard(
                  icon: Icons.local_shipping_rounded,
                  label: 'تخريج البيض',
                  color: cs.primary,
                  onTap: () => Navigator.pushNamed(context, '/dispatch'),
                ),
                _MenuCard(
                  icon: Icons.medical_services_rounded,
                  label: 'الأدوية',
                  color: AppStatusColors.warning(context),
                  onTap: () =>
                      Navigator.pushNamed(context, '/medications'),
                ),
                _MenuCard(
                  icon: Icons.inventory_2_rounded,
                  label: 'استلام علف',
                  color: cs.primary,
                  onTap: () =>
                      Navigator.pushNamed(context, '/feed-received'),
                ),
                _MenuCard(
                  icon: Icons.sticky_note_2_rounded,
                  label: 'ملاحظاتي',
                  color: cs.onSurfaceVariant,
                  onTap: () => Navigator.pushNamed(context, '/notes'),
                ),
                _MenuCard(
                  icon: Icons.settings_rounded,
                  label: 'الإعدادات',
                  color: cs.onSurfaceVariant,
                  onTap: () => Navigator.pushNamed(context, '/settings'),
                ),
                if (isManager) ...[
                  _MenuCard(
                    icon: Icons.payments_rounded,
                    label: 'قبض المبالغ',
                    color: AppStatusColors.success(context),
                    onTap: () =>
                        Navigator.pushNamed(context, '/payments'),
                  ),
                  _MenuCard(
                    icon: Icons.assessment_rounded,
                    label: 'التقارير',
                    color: AppStatusColors.info(context),
                    onTap: () => Navigator.pushNamed(context, '/reports'),
                  ),
                  _MenuCard(
                    icon: Icons.pets_rounded,
                    label: 'إدارة القطعان',
                    color: cs.primary,
                    onTap: () => Navigator.pushNamed(
                        context, '/flock-management'),
                  ),
                  _MenuCard(
                    icon: Icons.people_rounded,
                    label: 'الزبائن',
                    color: cs.onSurfaceVariant,
                    onTap: () =>
                        Navigator.pushNamed(context, '/customers'),
                  ),
                ],
              ]),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تسجيل الخروج'),
        content: const Text('هل تريد تسجيل الخروج من التطبيق؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('خروج'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await ref.read(authProvider.notifier).logout();
      if (context.mounted) {
        Navigator.of(context)
            .pushNamedAndRemoveUntil('/login', (_) => false);
      }
    }
  }
}

class _AppBarIcon extends StatelessWidget {
  final IconData icon;
  final int badge;
  final bool isSpinning;
  final VoidCallback? onTap;

  const _AppBarIcon({
    required this.icon,
    this.badge = 0,
    this.isSpinning = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: isSpinning
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(icon, color: Colors.white, size: 22),
          ),
        ),
        if (badge > 0)
          Positioned(
            right: -4,
            top: -4,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                shape: BoxShape.circle,
              ),
              constraints:
                  const BoxConstraints(minWidth: 18, minHeight: 18),
              child: Text(
                '$badge',
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

class _SyncStatusBanner extends StatelessWidget {
  final int pendingCount;
  final int failedCount;
  final DateTime? lastSyncAt;
  final bool isDark;

  const _SyncStatusBanner({
    required this.pendingCount,
    required this.failedCount,
    required this.lastSyncAt,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final success = AppStatusColors.success(context);

    if (pendingCount > 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_upload_outlined,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'لديك $pendingCount سجل غير مزامن — سيُرفع تلقائياً',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: success.withValues(alpha: isDark ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 18, color: success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'جميع السجلات متزامنة',
              style: TextStyle(
                fontSize: 12,
                color: success,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (lastSyncAt != null || failedCount > 0)
            Text(
              [
                if (lastSyncAt != null)
                  'آخر مزامنة ${lastSyncAt!.hour}:${lastSyncAt!.minute.toString().padLeft(2, '0')}',
                if (failedCount > 0) '$failedCount فاشل',
              ].join(' • '),
              style: TextStyle(
                fontSize: 11,
                color: failedCount > 0
                    ? AppStatusColors.warning(context)
                    : success,
              ),
            ),
        ],
      ),
    );
  }
}

class _PersistentNotices extends ConsumerWidget {
  final String farmId;

  const _PersistentNotices({required this.farmId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final noticesAsync = ref.watch(activeNoticesProvider(farmId));
    final notices = (noticesAsync.value ?? const <AppNotificationModel>[])
        .where((n) => n.isPersistent)
        .toList();

    if (notices.isEmpty) return const SizedBox.shrink();

    final visible = notices.take(3).toList();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'إشعارات المدير',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        for (final notice in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () =>
                  Navigator.pushNamed(context, '/notifications'),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: noticeColor(context, notice.level)
                      .withValues(alpha: 0.10),
                  border: Border.all(
                    color: noticeColor(context, notice.level)
                        .withValues(alpha: 0.4),
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                          width: 4,
                          color:
                              noticeColor(context, notice.level)),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              Icon(Icons.campaign_rounded,
                                  size: 18,
                                  color: noticeColor(
                                      context, notice.level)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  notice.body == null ||
                                          notice.body!.isEmpty
                                      ? notice.title
                                      : '${notice.title} — ${notice.body}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// ملخص يوم العامل — بيض / نفوق / علف
class _TodaySummaryCard extends ConsumerStatefulWidget {
  final String? farmId;

  const _TodaySummaryCard({required this.farmId});

  @override
  ConsumerState<_TodaySummaryCard> createState() =>
      _TodaySummaryCardState();
}

class _TodaySummaryCardState extends ConsumerState<_TodaySummaryCard> {
  int _eggs = 0;
  int _mortality = 0;
  double _feedKg = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // يُحدّث عند تغيّر عدد المعلّق (بعد إضافة سجل محلياً)
    ref.listen<int>(
      syncProvider.select((s) => s.pendingCount),
      (_, __) => _load(),
    );
  }

  Future<void> _load() async {
    final farmId = widget.farmId;
    if (farmId == null || farmId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final results = await Future.wait([
        ref.read(eggProductionRepositoryProvider).getTodayRecords(farmId),
        ref.read(mortalityRepositoryProvider).getTodayRecords(farmId),
        ref.read(feedRepositoryProvider).getTodayConsumption(farmId),
      ]);
      if (!mounted) return;
      setState(() {
        _eggs = (results[0] as List<EggProductionModel>)
            .fold<int>(0, (s, e) => s + e.totalEggs);
        _mortality = (results[1] as List<MortalityModel>)
            .fold<int>(0, (s, m) => s + m.count);
        _feedKg = (results[2] as List<FeedConsumptionModel>)
            .fold<double>(0, (s, f) => s + f.quantityKg);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: _loading
            ? const SizedBox(
                height: 56,
                child: Center(
                    child:
                        CircularProgressIndicator(strokeWidth: 2)))
            : Row(
                children: [
                  _TodayStat(
                    icon: Icons.egg_rounded,
                    label: 'بيض اليوم',
                    value: '$_eggs',
                    color: cs.primary,
                  ),
                  const SizedBox(width: 16),
                  _TodayStat(
                    icon: Icons.heart_broken_rounded,
                    label: 'نفوق اليوم',
                    value: '$_mortality',
                    color: AppStatusColors.danger(context),
                  ),
                  const SizedBox(width: 16),
                  _TodayStat(
                    icon: Icons.grass_rounded,
                    label: 'علف اليوم',
                    value: '${_feedKg.toStringAsFixed(0)} كغ',
                    color: AppStatusColors.info(context),
                  ),
                ],
              ),
      ),
    );
  }
}

class _TodayStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _TodayStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: color),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// صف أزرار التسجيل الكبيرة — نقرة واحدة للcroft اليومي
class _QuickActionsRow extends StatelessWidget {
  final bool isManager;

  const _QuickActionsRow({required this.isManager});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: _BigAction(
            icon: Icons.egg_rounded,
            label: 'تسجيل بيض',
            color: cs.primary,
            onTap: () =>
                Navigator.pushNamed(context, '/egg-production'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _BigAction(
            icon: Icons.heart_broken_rounded,
            label: 'تسجيل نفوق',
            color: AppStatusColors.danger(context),
            onTap: () =>
                Navigator.pushNamed(context, '/mortality'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _BigAction(
            icon: Icons.grain_rounded,
            label: 'علف',
            color: AppStatusColors.info(context),
            onTap: () =>
                Navigator.pushNamed(context, '/feed-consumption'),
          ),
        ),
      ],
    );
  }
}

class _BigAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _BigAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            color: isDark
                ? color.withValues(alpha: 0.18)
                : color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: color.withValues(alpha: isDark ? 0.3 : 0.25)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Column(
              children: [
                Icon(icon, color: color, size: 30),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w700,
                      fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final warning = AppStatusColors.warning(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: warning.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off_rounded, size: 18, color: warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'غير متصل بالإنترنت — البيانات تُحفظ محلياً',
              style: TextStyle(
                fontSize: 12,
                color: warning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _MenuCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: isDark
                ? color.withValues(alpha: 0.12)
                : color.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: color.withValues(alpha: isDark ? 0.25 : 0.2),
              width: 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, size: 26, color: color),
                ),
                const SizedBox(height: 10),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
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
