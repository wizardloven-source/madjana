import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../auth/providers/auth_provider.dart';
import '../../notifications/providers/notifications_provider.dart';
import '../../sync/providers/sync_provider.dart';

/// الشاشة الرئيسية
/// - بطاقة ترحيب مع زر خروج
/// - شريط حالة المزامنة
/// - قائمة عمليات حسب الدور (عامل/مدير)
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).currentUser;
    final syncState = ref.watch(syncProvider);
    final theme = Theme.of(context);

    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // تفعيل السحب من السحابة بمجرد توفر المزرعة
    final farmId = user.farmId;
    if (farmId != null && farmId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(syncProvider.notifier).setFarmId(farmId);
      });
    }

    final isManager = user.role == UserRole.manager;
    final pendingCount = syncState.pendingCount;

    // عدد الإشعارات الدائمة النشطة (لشارة الجرس)
    final persistentNotices =
        ref.watch(activeNoticesProvider(user.farmId ?? '')).value ??
            const <AppNotificationModel>[];
    final persistentCount =
        persistentNotices.where((n) => n.isPersistent).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('الرئيسية'),
        actions: [
          // جرس الإشعارات مع شارة الإشعارات الدائمة
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                tooltip: 'الإشعارات',
                icon: const Icon(Icons.notifications_outlined),
                onPressed: () => Navigator.pushNamed(context, '/notifications'),
              ),
              if (persistentCount > 0)
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      '$persistentCount',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.colorScheme.onError,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          // زر المزامنة مع عداد السجلات غير المرفوعة
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: syncState.isSyncing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                onPressed: syncState.isSyncing
                    ? null
                    : () => ref.read(syncProvider.notifier).syncNow(),
              ),
              if (pendingCount > 0 && !syncState.isSyncing)
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      '$pendingCount',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.colorScheme.onError,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // بطاقة الترحيب
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor:
                          theme.colorScheme.primary.withValues(alpha: 0.15),
                      child: Icon(
                        isManager ? Icons.admin_panel_settings : Icons.person,
                        size: 28,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'أهلاً، ${user.name}',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            user.role.label,
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // زر تسجيل الخروج
                    IconButton(
                      tooltip: 'تسجيل الخروج',
                      icon: Icon(Icons.logout,
                          color: theme.colorScheme.error),
                      onPressed: () => _confirmLogout(context, ref),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // إشعارات المدير الدائمة النشطة
            _PersistentNotices(farmId: user.farmId ?? ''),
            const SizedBox(height: 12),

            // شريط حالة المزامنة
            _SyncBanner(pendingCount: pendingCount, isDark: theme.brightness == Brightness.dark),
            const SizedBox(height: 16),

            // عنوان العمليات
            Text(
              'العمليات',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),

            // شبكة العمليات
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.6,
                children: [
                  _MenuCard(
                    icon: Icons.egg,
                    label: 'إدخال البيض',
                    color: Colors.green,
                    onTap: () =>
                        Navigator.pushNamed(context, '/egg-production'),
                  ),
                  _MenuCard(
                    icon: Icons.pets,
                    label: 'إدخال النفوق',
                    color: Colors.red,
                    onTap: () => Navigator.pushNamed(context, '/mortality'),
                  ),
                  _MenuCard(
                    icon: Icons.grain,
                    label: 'استهلاك العلف',
                    color: Colors.orange,
                    onTap: () =>
                        Navigator.pushNamed(context, '/feed-consumption'),
                  ),
                  _MenuCard(
                    icon: Icons.local_shipping,
                    label: 'تخريج البيض',
                    color: Colors.blue,
                    onTap: () => Navigator.pushNamed(context, '/dispatch'),
                  ),
                  _MenuCard(
                    icon: Icons.medical_services,
                    label: 'الأدوية',
                    color: Colors.purple,
                    onTap: () =>
                        Navigator.pushNamed(context, '/medications'),
                  ),
                  _MenuCard(
                    icon: Icons.inventory_2,
                    label: 'استلام علف',
                    color: Colors.brown,
                    onTap: () =>
                        Navigator.pushNamed(context, '/feed-received'),
                  ),
                  _MenuCard(
                    icon: Icons.sticky_note_2,
                    label: 'ملاحظاتي',
                    color: Colors.blueGrey,
                    onTap: () => Navigator.pushNamed(context, '/notes'),
                  ),
                  _MenuCard(
                    icon: Icons.settings,
                    label: 'الإعدادات',
                    color: Colors.teal,
                    onTap: () => Navigator.pushNamed(context, '/settings'),
                  ),
                  if (isManager) ...[
                    _MenuCard(
                      icon: Icons.payments,
                      label: 'قبض المبالغ',
                      color: Colors.indigo,
                      onTap: () =>
                          Navigator.pushNamed(context, '/payments'),
                    ),
                    _MenuCard(
                      icon: Icons.assessment,
                      label: 'التقارير',
                      color: Colors.deepOrange,
                      onTap: () => Navigator.pushNamed(context, '/reports'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
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
        Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
      }
    }
  }
}

/// شريط حالة المزامنة
/// شريط الإشعارات الدائمة من المدير (يظهر أعلى الرئيسية)
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

    return Column(
      children: [
        for (final notice in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.pushNamed(context, '/notifications'),
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
                          width: 4, color: noticeColor(context, notice.level)),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              Icon(Icons.campaign,
                                  size: 20,
                                  color:
                                      noticeColor(context, notice.level)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  notice.body == null ||
                                          notice.body!.isEmpty
                                      ? notice.title
                                      : '${notice.title} — ${notice.body}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13.5),
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

class _SyncBanner extends StatelessWidget {
  final int pendingCount;
  final bool isDark;

  const _SyncBanner({required this.pendingCount, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (pendingCount > 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_upload_outlined,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'لديك $pendingCount سجل غير مزامن - سيُرفع تلقائياً عند توفر الإنترنت',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: isDark ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 18, color: Colors.green.shade600),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('جميع السجلات متزامنة', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// بطاقة عملية في القائمة الرئيسية
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

    return Material(
      color: color.withValues(alpha: theme.brightness == Brightness.dark ? 0.18 : 0.09),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 24, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_left,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
