import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/design_tokens.dart';
import '../../auth/providers/auth_provider.dart';
import '../../reference_data/providers/reference_data_provider.dart';
import '../../sync/providers/sync_provider.dart';
import '../providers/auto_sync_provider.dart';
import '../providers/backup_provider.dart';
import '../providers/theme_provider.dart';

/// شاشة الإعدادات
/// 
/// المميزات:
/// - الوضع الليلي (مفعل افتراضياً)
/// - حالة المزامنة
/// - زر تسجيل الخروج
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).currentUser;
    final syncState = ref.watch(syncProvider);
    final isDarkMode = ref.watch(themeProvider);
    final autoSync = ref.watch(autoSyncProvider);
    final isConnected = syncState.connectionStatus != SyncConnectionStatus.disconnected;

    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // مؤشر حالة الاتصال
          if (!isConnected)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: const [
                  Icon(Icons.wifi_off, color: AppColors.warning, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('غير متصل بالإنترنت — البيانات ستُحفظ محلياً',
                        style: TextStyle(color: AppColors.warning)),
                  ),
                ],
              ),
            ),

          // معلومات المستخدم
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                const CircleAvatar(
                  radius: 32,
                  child: Icon(Icons.person, size: 32),
                ),
                const SizedBox(height: 12),
                Text(
                  user?.name ?? 'غير معروف',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  user?.role.label ?? '',
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  user?.phone ?? '',
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // إعدادات المدجنة (المصدر: سطح مكتب المدير)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'إعدادات المدجنة (من سطح المكتب)',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                if (user?.farmId == null || user!.farmId!.isEmpty)
                  const Text('لا توجد مدجنة نشطة')
                else
                  ref
                      .watch(farmSettingsProvider(user!.farmId!))
                      .when(
                        loading: () => const Center(
                          child: Padding(
                            padding: EdgeInsets.all(8),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                        error: (e, _) => const Text('تعذّر جلب إعدادات المدجنة'),
                        data: (farm) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildInfoRow('المدجنة', farm.name),
                            _buildInfoRow(
                              'وزن كيس العلف',
                              '${farm.feedBagWeightKg.toStringAsFixed(1)} كغ',
                            ),
                            _buildInfoRow('عدد البيض في الكرتون',
                                '${farm.eggsPerCarton}'),
                            _buildInfoRow(
                                'عدد البيض في الصينية', '${farm.eggsPerTray}'),
                            _buildInfoRow(
                              'معدل النفوق الافتراضي',
                              '${farm.defaultMortalityRate.toStringAsFixed(1)}%',
                            ),
                          ],
                        ),
                      ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _buildSettingTile(
            context,
            icon: Icons.dark_mode,
            title: 'الوضع الليلي',
            subtitle: 'تفعيل المظهر الداكن',
            trailing: Switch(
              value: isDarkMode,
              onChanged: (v) =>
                  ref.read(themeProvider.notifier).toggleTheme(v),
            ),
          ),
          const Divider(),

          // المزامنة التلقائية
          _buildSettingTile(
            context,
            icon: Icons.sync,
            title: 'المزامنة التلقائية',
            subtitle: 'رفع البيانات تلقائياً عند توفر الإنترنت',
            trailing: Switch(
              value: autoSync,
              onChanged: (v) {
                ref.read(autoSyncProvider.notifier).toggle(v);
                // ربط الإعداد بمحرك المزامنة الفعلي (إيقاف/تشغيل المؤقت الدوري)
                ref.read(syncProvider.notifier).setAutoSync(v);
              },
            ),
          ),
          const Divider(),

          // حالة المزامنة
          Container(
            margin: const EdgeInsets.symmetric(vertical: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.hairline.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'حالة المزامنة',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                _buildInfoRow(
                  'السجلات غير المرفوعة',
                  '${syncState.pendingCount}',
                  color: syncState.pendingCount > 0
                      ? const Color(AppConstants.colorWarning)
                      : const Color(AppConstants.colorSuccess),
                ),
                const SizedBox(height: 8),
                _buildInfoRow(
                  'السجلات الفاشلة',
                  '${syncState.failedCount}',
                  color: syncState.failedCount > 0
                      ? const Color(AppConstants.colorDanger)
                      : null,
                ),
                const SizedBox(height: 8),
                _buildInfoRow(
                  'آخر مزامنة',
                  syncState.lastSyncAt != null
                      ? Formatters.formatDateWithDay(syncState.lastSyncAt!)
                      : 'لم تتم بعد',
                ),
              ],
            ),
          ),

          // زر المزامنة الآن
          SizedBox(
            height: AppConstants.buttonMinHeight,
            child: ElevatedButton.icon(
              onPressed: syncState.isSyncing
                  ? null
                  : () => ref.read(syncProvider.notifier).syncNow(),
              icon: syncState.isSyncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.sync),
              label: Text(
                syncState.isSyncing ? 'جاري المزامنة...' : 'مزامنة الآن',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(AppConstants.colorInfo),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // النسخ الاحتياطي
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.hairline),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'النسخ الاحتياطي',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'حفظ نسخة من بيانات هذا الجهاز محلياً (SQLite) مع إمكانية استعادتها.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                _buildBackupSection(context, ref),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // معلومات التطبيق
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.hairline),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'معلومات التطبيق',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                _buildInfoRow('الإصدار', '1.0.0'),
                _buildInfoRow('البنية', 'Build 1'),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // زر تسجيل الخروج
          SizedBox(
            height: AppConstants.buttonMinHeight,
            child: ElevatedButton.icon(
              onPressed: () => _confirmLogout(context, ref),
              icon: const Icon(Icons.logout),
              label: const Text('تسجيل الخروج'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(AppConstants.colorDanger),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackupSection(BuildContext context, WidgetRef ref) {
    final backupState = ref.watch(backupProvider);
    final screen = this;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (backupState.errorMessage != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline,
                    color: AppColors.danger, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    backupState.errorMessage!,
                    style:
                        const TextStyle(color: AppColors.danger, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        _buildInfoRow(
          'عدد النسخ',
          '${backupState.backups.length}',
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: backupState.isBackingUp
                    ? null
                    : () => _handleCreateBackup(context, ref),
                icon: backupState.isBackingUp
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.backup, size: 18),
                label: Text(backupState.isBackingUp ? 'جاري...' : 'إنشاء نسخة'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: backupState.backups.isEmpty
                    ? null
                    : () => _showBackupPicker(context, ref),
                icon: const Icon(Icons.restore, size: 18),
                label: const Text('استعادة'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (backupState.lastBackup != null && backupState.lastBackup!.success)
          Text(
            'آخر نسخة: ${screen._formatSize(backupState.lastBackup!.metadata!.fileSizeBytes)} '
            'منذ ${screen._relativeTime(backupState.lastBackup!.metadata!.createdAt)}',
            style: const TextStyle(fontSize: 12),
          ),
        if (backupState.lastRestore != null)
          Text(
            backupState.lastRestore!.success
                ? 'تمت الاستعادة بنجاح — ${backupState.lastRestore!.recordsAffected} سجل'
                : 'فشلت الاستعادة: ${backupState.lastRestore!.errorMessage}',
            style: TextStyle(
              fontSize: 12,
              color: backupState.lastRestore!.success
                  ? const Color(AppConstants.colorSuccess)
                  : AppColors.danger,
            ),
          ),
      ],
    );
  }

  Future<void> _handleCreateBackup(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await ref.read(backupProvider.notifier).createBackup();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.success
              ? 'تم إنشاء النسخة الاحتياطية بنجاح'
              : 'فشل إنشاء النسخة: ${result.errorMessage}',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showBackupPicker(BuildContext context, WidgetRef ref) {
    final backups = ref.read(backupProvider).backups;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: backups.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Text('لا توجد نسخ احتياطية'),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'اختر نسخة للاستعادة',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  ...backups.map((b) => ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(b.id),
                        subtitle: Text(
                            '${_formatSize(b.fileSizeBytes)} — ${_relativeTime(b.createdAt)}'),
                        onTap: () {
                          Navigator.pop(ctx);
                          _confirmRestore(context, ref, b.id);
                        },
                      )),
                ],
              ),
      ),
    );
  }

  void _confirmRestore(
      BuildContext context, WidgetRef ref, String backupId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد الاستعادة'),
        content: const Text(
          'سيتم استبدال البيانات الحالية بالنسخة الاحتياطية.\n'
          'يُنصح بإنشاء نسخة احتياطية قبل الاستعادة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final messenger = ScaffoldMessenger.of(context);
              final result =
                  await ref.read(backupProvider.notifier).restoreBackup(backupId);
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    result.success
                        ? 'تمت الاستعادة بنجاح (${result.recordsAffected} سجل)'
                        : 'فشلت الاستعادة: ${result.errorMessage}',
                  ),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.danger,
            ),
            child: const Text('استعادة'),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes بايت';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} ك.ب';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} م.ب';
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inHours < 1) return '${diff.inMinutes} دقيقة';
    if (diff.inDays < 1) return '${diff.inHours} ساعة';
    return '${diff.inDays} يوم';
  }

  Widget _buildSettingTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: trailing,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? color}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 14)),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  void _confirmLogout(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد تسجيل الخروج'),
        content: const Text('سيتم تسجيل الخروج من هذا الجهاز. هل أنت متأكد؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await ref.read(authProvider.notifier).logout();
              if (context.mounted) {
                Navigator.of(context).pushNamedAndRemoveUntil(
                  '/login',
                  (route) => false,
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(AppConstants.colorDanger),
            ),
            child: const Text('تسجيل الخروج'),
          ),
        ],
      ),
    );
  }
}