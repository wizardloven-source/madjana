import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../core/providers.dart';
import '../sync/providers/sync_provider.dart';

/// مركز المزامنة للعامل
/// يعرض حالة المزامنة الحقيقية وسجل العمليات وإمكانية المزامنة اليدوية
class SyncCenterScreen extends ConsumerStatefulWidget {
  const SyncCenterScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<SyncCenterScreen> createState() => _SyncCenterScreenState();
}

class _SyncCenterScreenState extends ConsumerState<SyncCenterScreen> {
  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncProvider);
    final history = ref.watch(syncHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('مركز المزامنة'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: syncState.isSyncing
                ? null
                : () => _performSync(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(syncHistoryProvider);
          await _performSync();
        },
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // بطاقة الحالة العامة
              _buildStatusCard(syncState),
              const SizedBox(height: 24),

              // إحصائيات مفصلة
              _buildStatsGrid(syncState),
              const SizedBox(height: 24),

              // سجل المزامنة
              _buildSyncLog(history),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard(SyncState syncState) {
    final failed = syncState.failedCount > 0;
    final pending = syncState.pendingCount > 0;
    final statusColor = failed
        ? Colors.orange
        : (pending ? Colors.blue : Colors.green);
    final statusText = failed
        ? 'توجد أخطاء'
        : (pending ? 'قيد الانتظار' : 'محدث');

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [statusColor.withOpacity(0.1), statusColor.withOpacity(0.3)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 120,
                  height: 120,
                  child: CircularProgressIndicator(
                    value: syncState.isSyncing ? null : 1.0,
                    strokeWidth: 8,
                    backgroundColor: Colors.grey[200],
                    color: statusColor,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      syncState.isSyncing ? Icons.sync : Icons.cloud_done,
                      size: 48,
                      color: statusColor,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      syncState.isSyncing ? 'جاري...' : '${syncState.pendingCount}',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              statusText,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: statusColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              syncState.lastSyncAt != null
                  ? 'آخر مزامنة: ${_formatDateTime(syncState.lastSyncAt!)}'
                  : 'لم تتم مزامنة بعد',
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: syncState.isSyncing ? null : () => _performSync(),
              icon: Icon(syncState.isSyncing ? Icons.sync : Icons.cloud_upload),
              label: Text(syncState.isSyncing ? 'جاري المزامنة...' : 'مزامنة الآن'),
              style: ElevatedButton.styleFrom(
                backgroundColor: statusColor,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsGrid(SyncState syncState) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 3,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1,
      children: [
        _buildStatItem('قيد الانتظار', syncState.pendingCount, Colors.blue, Icons.pending),
        _buildStatItem('تم المزامنة', syncState.syncedCount, Colors.green, Icons.check_circle),
        _buildStatItem('فشل', syncState.failedCount, Colors.red, Icons.error),
      ],
    );
  }

  Widget _buildStatItem(String label, int count, Color color, IconData icon) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 8),
            Text(
              count.toString(),
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncLog(AsyncValue<List<SyncHistoryEntry>> history) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'سجل المزامنة',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const Divider(),
            ...history.when(
              data: (entries) => entries.isEmpty
                  ? [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'لا توجد عمليات مزامنة بعد',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ),
                    ]
                  : entries.map(_buildHistoryTile).toList(),
              loading: () => const [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
              error: (e, _) => [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'تعذر تحميل سجل المزامنة',
                    style: TextStyle(color: Colors.red[400]),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryTile(SyncHistoryEntry entry) {
    final isError = entry.failed > 0 || (entry.errorMessage?.isNotEmpty ?? false);
    final color = isError ? Colors.orange : Colors.green;
    final message = isError
        ? (entry.errorMessage ?? 'فشل في ${entry.failed} عملية')
        : 'تمت المزامنة بنجاح';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withOpacity(0.1),
        child: Icon(
          isError ? Icons.error : Icons.check,
          color: color,
          size: 20,
        ),
      ),
      title: Text(
        'رفع ${entry.uploaded} · سحب ${entry.downloaded}',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Text(message, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      trailing: Text(
        _formatRelativeTime(entry.createdAt),
        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
      ),
    );
  }

  Future<void> _performSync() async {
    await ref.read(syncProvider.notifier).syncNow();
    if (!mounted) return;
    ref.invalidate(syncHistoryProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تمت المزامنة بنجاح'),
        backgroundColor: Colors.green,
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} - ${dt.day}/${dt.month}';
  }

  String _formatRelativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inHours < 24) return 'منذ ${diff.inHours} ساعة';
    return 'منذ ${diff.inDays} يوم';
  }
}

/// جلب سجل عمليات المزامنة الحقيقية من طبقة البيانات
final syncHistoryProvider = FutureProvider.autoDispose<List<SyncHistoryEntry>>((ref) {
  final repo = ref.watch(syncRepositoryProvider);
  return repo.getSyncHistory(limit: 20);
});
