import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  bool _loading = true;
  List<AppNotificationModel> _notices = [];
  List<FlockModel> _flocks = [];

  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  String _level = 'info';
  bool _persistent = false;
  String? _flockId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);

    final user = ref.read(authProvider).currentUser;
    final farmId = user?.farmId ?? '';

    try {
      _flocks =
          await ref.read(flockRepositoryProvider).getFlocks(farmId, includeEnded: true);

      final rows = await ref.read(supabaseClientProvider).from(
        'app_notifications',
      ).select().eq('farm_id', farmId).order('created_at', ascending: false);

      _notices = ((rows as List).cast<Map<String, dynamic>>())
          .map(AppNotificationModel.fromJson)
          .toList();
    } catch (_) {
      _notices = [];
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _create() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اكتب عنوان الإشعار')),
      );
      return;
    }

    final user = ref.read(authProvider).currentUser;
    if (user == null) return;

    setState(() => _saving = true);
    try {
      await ref.read(supabaseClientProvider).from('app_notifications').insert({
        'farm_id': user.farmId,
        if (_flockId != null && _flockId!.isNotEmpty) 'flock_id': _flockId,
        'title': title,
        if (_bodyCtrl.text.trim().isNotEmpty)
          'body': _bodyCtrl.text.trim(),
        'level': _level,
        'is_persistent': _persistent,
        'is_active': true,
      });

      _titleCtrl.clear();
      _bodyCtrl.clear();
      setState(() {
        _level = 'info';
        _persistent = false;
        _flockId = null;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إنشاء الإشعار')),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل الإنشاء: $e')),
        );
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _toggleActive(AppNotificationModel notice) async {
    try {
      await ref.read(supabaseClientProvider).from('app_notifications')
          .update({'is_active': !notice.isActive}).eq('id', notice.id);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل التحديث: $e')),
        );
      }
    }
  }

  Future<void> _delete(AppNotificationModel notice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الإشعار'),
        content: Text(notice.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref
          .read(supabaseClientProvider)
          .from('app_notifications')
          .delete()
          .eq('id', notice.id);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل الحذف: $e')),
        );
      }
    }
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'danger':
        return Theme.of(context).colorScheme.error;
      case 'warning':
        return Colors.orange.shade700;
      default:
        return Theme.of(context).colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final dateFormat = DateFormat('yyyy/MM/dd HH:mm');

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // قائمة الإشعارات (الجانب الأيمن في RTL = المحتوى الرئيسي)
                Expanded(
                  flex: 3,
                  child: Card(
                    child: _notices.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.notifications_none,
                                    size: 48,
                                    color: Theme.of(context).colorScheme.outline),
                                const SizedBox(height: 12),
                                Text('لا توجد إشعارات بعد',
                                    style: TextStyle(
                                        color: Theme.of(context).colorScheme.outline)),
                              ],
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: _notices.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final notice = _notices[i];
                              final color = _levelColor(notice.level);

                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: color.withValues(alpha: 0.15),
                                  child: Icon(Icons.notifications_outlined,
                                      color: color),
                                ),
                                title: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        notice.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: notice.isActive
                                              ? null
                                              : Colors.grey,
                                          decoration: notice.isActive
                                              ? null
                                              : TextDecoration.lineThrough,
                                        ),
                                      ),
                                    ),
                                    if (notice.isPersistent) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: color.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        child: Text('دائم',
                                            style: TextStyle(
                                                fontSize: 11, color: color)),
                                      ),
                                    ],
                                  ],
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (notice.body != null &&
                                        notice.body!.isNotEmpty)
                                      Text(notice.body!,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis),
                                    const SizedBox(height: 2),
                                    Text(
                                      dateFormat.format(
                                          notice.createdAt ?? DateTime.now()),
                                      style: TextStyle(
                                          fontSize: 11, color: Colors.grey[600]),
                                    ),
                                  ],
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: notice.isActive
                                          ? 'تعطيل'
                                          : 'تنشيط',
                                      icon: Icon(notice.isActive
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined),
                                      onPressed: () => _toggleActive(notice),
                                    ),
                                    IconButton(
                                      tooltip: 'حذف',
                                      icon: Icon(Icons.delete_outline,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error),
                                      onPressed: () => _delete(notice),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ),

                const SizedBox(width: 24),

                // نموذج الإنشاء (الجانب الأيسر في RTL)
                SizedBox(
                  width: 340,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.campaign,
                                    color:
                                        Theme.of(context).colorScheme.primary),
                                const SizedBox(width: 8),
                                const Text('إشعار جديد',
                                    style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold)),
                              ],
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _titleCtrl,
                              decoration: const InputDecoration(
                                  labelText: 'العنوان *'),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _bodyCtrl,
                              maxLines: 3,
                              decoration:
                                  const InputDecoration(labelText: 'التفاصيل'),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              value: _flockId,
                              decoration: const InputDecoration(
                                  labelText: 'المدجنة (اختياري)'),
                              items: [
                                const DropdownMenuItem(
                                    value: null,
                                    child: Text('جميع المداجن / الكل')),
                                ..._flocks.map((f) => DropdownMenuItem(
                                      value: f.id,
                                      child: Text(f.displayName),
                                    )),
                              ],
                              onChanged: (v) =>
                                  setState(() => _flockId = v),
                            ),
                            const SizedBox(height: 12),
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(
                                    value: 'info', label: Text('عادي')),
                                ButtonSegment(
                                    value: 'warning', label: Text('تحذير')),
                                ButtonSegment(
                                    value: 'danger', label: Text('هام')),
                              ],
                              selected: {_level},
                              onSelectionChanged: (v) =>
                                  setState(() => _level = v.first),
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('إشعار دائم'),
                              subtitle: const Text(
                                  'يظهر دائماً في الصفحة الرئيسية حتى بعد نقر المستخدم'),
                              value: _persistent,
                              onChanged: (v) =>
                                  setState(() => _persistent = v),
                            ),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              icon: _saving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Icon(Icons.send),
                              label: const Text('نشر الإشعار'),
                              onPressed: _saving ? null : _create,
                            ),
                          ],
                        ),
                      ),
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
