import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/providers/auth_provider.dart';
import '../../../shared/widgets/modern_ui.dart';
import '../providers/notifications_provider.dart';

/// شاشة الإشعارات:
/// - تبويب 1: إشعارات المدير (من السحابة)
/// - تبويب 2: تذكيراتي الخاصة (محلية على الهاتف)
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).currentUser;

    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الإشعارات'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'إشعارات المدير', icon: Icon(Icons.campaign)),
              Tab(text: 'تذكيراتي', icon: Icon(Icons.alarm)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ManagerNoticesTab(farmId: user.farmId ?? ''),
            const _RemindersTab(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// تبويب إشعارات المدير
// ---------------------------------------------------------------------------
class _ManagerNoticesTab extends ConsumerWidget {
  final String farmId;

  const _ManagerNoticesTab({required this.farmId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final noticesAsync = ref.watch(activeNoticesProvider(farmId));

    return RefreshIndicator(
      onRefresh: () => ref.refresh(activeNoticesProvider(farmId).future),
      child: noticesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => ListView(
          children: const [
            SizedBox(height: 120),
            Center(child: Text('تعذر تحميل الإشعارات')),
          ],
        ),
        data: (notices) {
          if (notices.isEmpty) {
            return ListView(
              children: const [
                SizedBox(height: 120),
                Icon(Icons.notifications_off_outlined,
                    size: 56, color: Colors.grey),
                SizedBox(height: 12),
                Center(child: Text('لا توجد إشعارات حالياً')),
              ],
            );
          }

          return ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            itemCount: notices.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final notice = notices[i];
              final color = noticeColor(context, notice.level);

              return Card(
                margin: EdgeInsets.zero,
                elevation: 1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(width: 5, color: color),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      notice.title,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ),
                                  if (notice.isPersistent)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: color.withValues(alpha: 0.15),
                                        borderRadius:
                                            BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        'دائم',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: color,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              if (notice.body != null &&
                                  notice.body!.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(notice.body!),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// تبويب التذكيرات المحلية للعامل
// ---------------------------------------------------------------------------
class _RemindersTab extends ConsumerWidget {
  const _RemindersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(remindersProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add_reminder',
        onPressed: () => _showComposer(context, ref),
        icon: const Icon(Icons.add_alarm),
        label: const Text('تذكير جديد'),
      ),
      body: state.reminders.isEmpty
          ? ListView(
              children: const [
                SizedBox(height: 120),
                Icon(Icons.alarm_off, size: 56, color: Colors.grey),
                SizedBox(height: 12),
                Center(child: Text('لا توجد تذكيرات — أضف تذكيراً خاصاً بك')),
              ],
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: state.reminders.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final reminder = state.reminders[i];

                return Dismissible(
                  key: ValueKey(reminder.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.only(left: 20),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.error,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (_) async {
                    return await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('حذف التذكير؟'),
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
                        ) ??
                        false;
                  },
                  onDismissed: (_) =>
                      ref.read(remindersProvider.notifier).delete(reminder.id),
                  child: Card(
                    margin: EdgeInsets.zero,
                    elevation: 1,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.15),
                        child: Icon(
                          Icons.alarm,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      title: Text(
                        reminder.title,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: reminder.body == null ||
                              reminder.body!.isEmpty
                          ? null
                          : Text(reminder.body!),
                      trailing: IconButton(
                        icon: Icon(Icons.delete_outline,
                            color: Theme.of(context).colorScheme.error),
                        onPressed: () => ref
                            .read(remindersProvider.notifier)
                            .delete(reminder.id),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  void _showComposer(BuildContext context, WidgetRef ref) {
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'تذكير جديد',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'يبقى على هاتفك فقط ولا يراه أحد',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'العنوان *',
                hintText: 'مثال: إعطاء الدواء للعنبر 2',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: bodyCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'تفاصيل',
                hintText: 'اختياري',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.check),
              label: const Text('حفظ'),
              onPressed: () {
                final title = titleCtrl.text.trim();
                if (title.isEmpty) {
                  AppSnack.warning(ctx, 'اكتب عنوان التذكير');
                  return;
                }
                ref.read(remindersProvider.notifier).add(
                      title: title,
                      body: bodyCtrl.text.trim(),
                    );
                Navigator.pop(ctx);
                AppSnack.success(ctx, 'تم حفظ التذكير');
              },
            ),
          ],
        ),
      ),
    );
  }
}
