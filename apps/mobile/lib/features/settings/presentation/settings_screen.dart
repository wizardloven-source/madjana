import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../auth/providers/auth_provider.dart';
import '../../sync/providers/sync_provider.dart';
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

    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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

          // الوضع الليلي
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
              value: true,
              onChanged: (value) {
                // TODO: ربط بـ Provider عند إضافة إعداد المزامنة التلقائية
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('هذه الميزة قيد التطوير'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
          ),
          const Divider(),

          // حالة المزامنة
          Container(
            margin: const EdgeInsets.symmetric(vertical: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.1),
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

          // معلومات التطبيق
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
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
        content: const Text('سيتم مسح البيانات غير المزامنة. هل أنت متأكد؟'),
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
