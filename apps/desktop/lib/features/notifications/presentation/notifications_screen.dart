import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

/// ط´ط§ط´ط© ط¥ط¯ط§ط±ط© ط§ظ„ط¥ط´ط¹ط§ط±ط§طھ:
/// - ط§ظ„ظ…ط¯ظٹط± ظٹظ†ط´ط¦ ط¥ط´ط¹ط§ط±ط§طھ ط¯ط§ط¦ظ…ط© ط£ظˆ ط¹ط§ط¯ظٹط© ظ„ظ…ط¯ط¬ظ†طھظ‡
/// - طھط¸ظ‡ط± ظ„ظ„ط¹ط§ظ…ظ„ظٹظ† ظپظٹ طھط·ط¨ظٹظ‚ ط§ظ„ظ…ظˆط¨ط§ظٹظ„
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
        const SnackBar(content: Text('ط§ظƒطھط¨ ط¹ظ†ظˆط§ظ† ط§ظ„ط¥ط´ط¹ط§ط±')),
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
          const SnackBar(content: Text('طھظ… ط¥ظ†ط´ط§ط، ط§ظ„ط¥ط´ط¹ط§ط±')),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ظپط´ظ„ ط§ظ„ط¥ظ†ط´ط§ط،: $e')),
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
          SnackBar(content: Text('ظپط´ظ„ ط§ظ„طھط­ط¯ظٹط«: $e')),
        );
      }
    }
  }

  Future<void> _delete(AppNotificationModel notice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ط­ط°ظپ ط§ظ„ط¥ط´ط¹ط§ط±طں'),
        content: Text(notice.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ط¥ظ„ط؛ط§ط،'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ط­ط°ظپ'),
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
          SnackBar(content: Text('ظپط´ظ„ ط§ظ„ط­ط°ظپ: $e')),
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ظ„ظˆط­ط© ط§ظ„ط¥ظ†ط´ط§ط،
          SizedBox(
            width: 340,
            child: Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.campaign,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        const Text('ط¥ط´ط¹ط§ط± ط¬ط¯ظٹط¯',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _titleCtrl,
                      decoration: const InputDecoration(labelText: 'ط§ظ„ط¹ظ†ظˆط§ظ† *'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _bodyCtrl,
                      maxLines: 3,
                      decoration:
                          const InputDecoration(labelText: 'ط§ظ„طھظپط§طµظٹظ„'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _flockId,
                      decoration: const InputDecoration(
                          labelText: 'ط§ظ„ظ…ط¯ط¬ظ†ط© (ط§ط®طھظٹط§ط±ظٹ â€” ظٹط¸ظ‡ط± ظ„ظ„ظƒظ„ ط¥ط°ط§ طھط±ظƒطھ ظپط§ط±ط؛ط§ظ‹)'),
                      items: [
                        const DropdownMenuItem(
                            value: null, child: Text('ط¬ظ…ظٹط¹ ط§ظ„ظ…ط¯ط§ط¬ظ† / ط§ظ„ظƒظ„')),
                        ..._flocks.map((f) => DropdownMenuItem(
                              value: f.id,
                              child: Text(f.displayName),
                            )),
                      ],
                      onChanged: (v) => setState(() => _flockId = v),
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'info', label: Text('ط¹ط§ط¯ظٹ')),
                        ButtonSegment(value: 'warning', label: Text('طھط­ط°ظٹط±')),
                        ButtonSegment(value: 'danger', label: Text('ظ‡ط§ظ…')),
                      ],
                      selected: {_level},
                      onSelectionChanged: (v) =>
                          setState(() => _level = v.first),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('ط¥ط´ط¹ط§ط± ط¯ط§ط¦ظ…'),
                      subtitle: const Text(
                          'ظٹط¨ظ‚ظ‰ ط¸ط§ظ‡ط±ط§ظ‹ ظپظٹ ط§ظ„ط±ط¦ظٹط³ظٹط© ط­طھظ‰ طھط¹ط·ظ„ظ‡ ط¨ظ†ظپط³ظƒ'),
                      value: _persistent,
                      onChanged: (v) => setState(() => _persistent = v),
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
                      label: const Text('ظ†ط´ط± ط§ظ„ط¥ط´ط¹ط§ط±'),
                      onPressed: _saving ? null : _create,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 24),

          // ظ‚ط§ط¦ظ…ط© ط§ظ„ط¥ط´ط¹ط§ط±ط§طھ
          Expanded(
            child: Card(
              elevation: 2,
              child: _notices.isEmpty
                  ? const Center(child: Text('ظ„ط§ طھظˆط¬ط¯ ط¥ط´ط¹ط§ط±ط§طھ ط¨ط¹ط¯'))
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
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color:
                                        notice.isActive ? null : Colors.grey,
                                    decoration: notice.isActive
                                        ? null
                                        : TextDecoration.lineThrough,
                                  ),
                                ),
                              ),
                              if (notice.isPersistent)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text('ط¯ط§ط¦ظ…',
                                      style: TextStyle(
                                          fontSize: 11, color: color)),
                                ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (notice.body != null &&
                                  notice.body!.isNotEmpty)
                                Text(notice.body!),
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
                                    ? 'طھط¹ط·ظٹظ„'
                                    : 'طھظ†ط´ظٹط·',
                                icon: Icon(notice.isActive
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined),
                                onPressed: () => _toggleActive(notice),
                              ),
                              IconButton(
                                tooltip: 'ط­ط°ظپ',
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
        ],
      ),
    );
  }
}
