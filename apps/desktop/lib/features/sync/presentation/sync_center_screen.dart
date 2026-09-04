import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/design_tokens.dart';
import '../../../core/providers.dart';

/// شاشة مركز المزامنة (SYNC CENTER) — للـ system_admin فقط.
/// يعرض صحة مزامنة كل المداجن: الأجهزة/حالتها، التعارضات، وآخر مزامنة.
class SyncCenterScreen extends ConsumerStatefulWidget {
  const SyncCenterScreen({super.key});

  @override
  ConsumerState<SyncCenterScreen> createState() => _SyncCenterScreenState();
}

class _SyncCenterScreenState extends ConsumerState<SyncCenterScreen> {
  List<SyncHealthEntry> _entries = [];
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (silent && _loading) return;
    if (!silent) setState(() => _loading = true);
    try {
      final data = await ref
          .read(userAdminRepositoryProvider)
          .getSyncHealth(onlineWindowMinutes: 5);
      if (!mounted) return;
      setState(() => _entries = data);
    } catch (_) {
      // أبقِ العرض السابق عند أي خطأ
    } finally {
      if (!silent && mounted) setState(() => _loading = false);
    }
  }

  String _relativeTime(DateTime? time) {
    if (time == null) return '—';
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) return 'قبل ${diff.inMinutes} دقيقة';
    if (diff.inHours < 24) return 'قبل ${diff.inHours} ساعة';
    return 'قبل ${diff.inDays} يوم';
  }

  Color _healthColor(SyncHealthEntry e, ThemeData theme) {
    if (e.pendingConflicts > 0) return AppStatusColors.danger(context);
    if (e.deviceCount > 0 && e.onlineDevices == 0) {
      return AppStatusColors.warning(context);
    }
    return AppStatusColors.success(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        title: const Text('مركز المزامنة'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: () => _load(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? _EmptyState(onRefresh: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    children: [
                      _SummaryBar(entries: _entries),
                      const SizedBox(height: AppSpacing.lg),
                      ..._entries.map(
                        (e) => _FarmHealthCard(
                          entry: e,
                          relativeTime: _relativeTime(e.lastSync),
                          accent: _healthColor(e, theme),
                          onRefresh: _load,
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

/// شريط ملخّص عام: عدد المداجن، الأجهزة، المتّصلة، التعارضات.
class _SummaryBar extends StatelessWidget {
  final List<SyncHealthEntry> entries;
  const _SummaryBar({required this.entries});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalDevices = entries.fold<int>(0, (s, e) => s + e.deviceCount);
    final online = entries.fold<int>(0, (s, e) => s + e.onlineDevices);
    final conflicts = entries.fold<int>(0, (s, e) => s + e.pendingConflicts);
    final hasOfflineFarms =
        entries.any((e) => e.deviceCount > 0 && e.offlineDevices > 0);

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.radiusLg,
      ),
      child: Row(
        children: [
          _SummaryStat(label: 'المداجن', value: '${entries.length}'),
          _SummaryStat(label: 'الأجهزة', value: '$totalDevices'),
          _SummaryStat(
            label: 'متصل',
            value: '$online',
            color: AppStatusColors.success(context),
          ),
          _SummaryStat(
            label: 'تعارضات',
            value: '$conflicts',
            color: conflicts > 0
                ? AppStatusColors.danger(context)
                : theme.colorScheme.onSurface,
          ),
          const Spacer(),
          if (hasOfflineFarms)
            Icon(Icons.warning_amber_rounded,
                color: AppStatusColors.warning(context))
          else
            Icon(Icons.check_circle_rounded,
                color: AppStatusColors.success(context)),
        ],
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _SummaryStat({
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: AppTypography.title,
              fontWeight: FontWeight.w800,
              color: color ?? theme.colorScheme.onSurface,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: AppTypography.caption,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// بطاقة مزرعة ضمن SYNC CENTER.
class _FarmHealthCard extends StatelessWidget {
  final SyncHealthEntry entry;
  final String relativeTime;
  final Color accent;
  final VoidCallback onRefresh;
  const _FarmHealthCard({
    required this.entry,
    required this.relativeTime,
    required this.accent,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: AppRadius.radiusLg,
        border: Border.all(
          color: accent.withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  entry.farmName,
                  style: const TextStyle(
                    fontSize: AppTypography.title,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'تحديث',
                iconSize: 18,
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              _FarmMetric(
                icon: Icons.devices_rounded,
                label: 'أجهزة',
                value: '${entry.deviceCount}',
              ),
              _FarmMetric(
                icon: Icons.cloud_done_rounded,
                label: 'متصل',
                value: '${entry.onlineDevices}',
                color: AppStatusColors.success(context),
              ),
              _FarmMetric(
                icon: Icons.cloud_off_rounded,
                label: 'غير متصل',
                value: '${entry.offlineDevices}',
                color: entry.offlineDevices > 0
                    ? AppStatusColors.warning(context)
                    : theme.colorScheme.onSurfaceVariant,
              ),
              _FarmMetric(
                icon: Icons.report_gmailerrorred_rounded,
                label: 'تعارضات',
                value: '${entry.pendingConflicts}',
                color: entry.pendingConflicts > 0
                    ? AppStatusColors.danger(context)
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Icon(Icons.schedule_rounded,
                  size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: AppSpacing.xxs),
              Text(
                'آخر مزامنة: $relativeTime',
                style: TextStyle(
                  fontSize: AppTypography.caption,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FarmMetric extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;
  const _FarmMetric({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Row(
        children: [
          Icon(icon, size: 18, color: color ?? theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.xxs),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: AppTypography.bodyLg,
                  fontWeight: FontWeight.w800,
                  color: color ?? theme.colorScheme.onSurface,
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTypography.caption,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onRefresh;
  const _EmptyState({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sync_rounded,
              size: 56, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: AppSpacing.md),
          Text(
            'لا توجد بيانات مزامنة بعد',
            style: TextStyle(
              fontSize: AppTypography.title,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'ستظهر المداجن هنا بمجرد بدء أي جهاز بالمزامنة.',
            style: TextStyle(
              fontSize: AppTypography.bodySm,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('تحديث'),
          ),
        ],
      ),
    );
  }
}
