import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../../core/shell_state.dart';
import '../../../core/design_tokens.dart';
import '../../auth/providers/auth_provider.dart';

/// مركز المزامنة - سطح المكتب
/// يعرض حالة المزامنة الحقيقية، وعدد العمليات قيد الانتظار/المزامنة/الفاشلة،
/// وتفصيل طابور العمليات، وسجل عمليات المزامنة، مع إمكانية المزامنة اليدوية
/// وإعادة محاولة العمليات الفاشلة.
class SyncCenterScreen extends ConsumerStatefulWidget {
  const SyncCenterScreen({super.key});

  @override
  ConsumerState<SyncCenterScreen> createState() => _SyncCenterScreenState();
}

class _SyncCenterScreenState extends ConsumerState<SyncCenterScreen> {
  List<SyncChangeModel> _queueItems = [];
  bool _loading = true;
  bool _syncing = false;
  int _pending = 0;
  int _synced = 0;
  int _failed = 0;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
    ref.listen(dataRefreshTickProvider, (_, _) => _load());
  }

  Future<void> _load() async {
    final repo = ref.read(syncRepositoryProvider);
    try {
      final results = await Future.wait([
        repo.getQueueItems(limit: 100),
        repo.getPendingCount(),
        repo.getSyncedCount(),
        repo.getFailedCount(),
      ]);
      if (!mounted) return;
      setState(() {
        _queueItems = results[0] as List<SyncChangeModel>;
        _pending = results[1] as int;
        _synced = results[2] as int;
        _failed = results[3] as int;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    final farmId = _farmId;
    try {
      final repo = ref.read(syncRepositoryProvider);
      final result = await repo.syncNow(farmId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.isSuccess
                ? 'تمت المزامنة: رفع ${result.uploadedCount} · سحب ${result.downloadedCount}'
                : 'اكتملت المزامنة مع ${result.failedCount} سجل فاشل',
          ),
          backgroundColor: result.isSuccess ? Colors.green : Colors.orange,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('فشلت المزامنة: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
        _load();
      }
    }
  }

  Future<void> _retryFailed() async {
    final repo = ref.read(syncRepositoryProvider);
    final count = await repo.retryAllFailed();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تمت إعادة محاولة $count عملية فاشلة')),
    );
    await _syncNow();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = _failed > 0
        ? theme.colorScheme.error
        : (_pending > 0 ? AppStatusColors.warning(context) : AppStatusColors.success(context));
    final statusText = _failed > 0
        ? '$_failed عملية فاشلة تحتاج إعادة محاولة'
        : (_pending > 0 ? '$_pending عملية قيد الانتظار' : 'المزامنة محدثة');

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sync_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                'مركز المزامنة',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _syncing ? null : _syncNow,
                icon: Icon(_syncing ? Icons.sync : Icons.cloud_upload_outlined),
                label: Text(_syncing ? 'جاري المزامنة...' : 'مزامنة الآن'),
              ),
              const SizedBox(width: 8),
              if (_failed > 0)
                FilledButton.icon(
                  onPressed: _syncing ? null : _retryFailed,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  ),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text('إعادة المحاولة ($_failed)'),
                ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'تحديث',
                icon: const Icon(Icons.refresh),
                onPressed: _loading ? null : _load,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // بطاقة الحالة
          Card(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(statusColor == const Color(0xFF000000)
                      ? Icons.cloud_done
                      : Icons.cloud_done,
                      color: statusColor, size: 40),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(statusText,
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: statusColor)),
                        const SizedBox(height: 4),
                        Text(_farmId.isEmpty
                            ? 'لم تختر مدجنة بعد'
                            : 'المدجنة النشطة',
                            style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  _StatChip(label: 'قيد الانتظار', value: '$_pending', color: AppStatusColors.warning(context)),
                  const SizedBox(width: 8),
                  _StatChip(label: 'تمت المزامنة', value: '$_synced', color: AppStatusColors.success(context)),
                  const SizedBox(width: 8),
                  _StatChip(label: 'فاشلة', value: '$_failed', color: theme.colorScheme.error),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // تفصيل طابور العمليات
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.receipt_long_outlined,
                            color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        const Text('عمليات الطابور',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 12),
                        Text('آخر 100 عملية',
                            style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                    const Divider(),
                    if (_loading)
                      const Expanded(
                          child: Center(child: CircularProgressIndicator()))
                    else if (_queueItems.isEmpty)
                      Expanded(
                          child: Center(
                              child: Text('لا توجد عمليات في الطابور')))
                    else
                      Expanded(
                        child: SingleChildScrollView(
                          child: DataTable(
                            headingRowHeight: 40,
                            dataRowMinHeight: 36,
                            dataRowMaxHeight: 44,
                            columns: const [
                              DataColumn(label: Text('الجدول')),
                              DataColumn(label: Text('العملية')),
                              DataColumn(label: Text('المعرف')),
                              DataColumn(label: Text('الحالة')),
                              DataColumn(label: Text('المحاولات')),
                              DataColumn(label: Text('الخطأ')),
                            ],
                            rows: [
                              for (final item in _queueItems)
                                DataRow(cells: [
                                  DataCell(Text(_tableLabel(item.tableName))),
                                  DataCell(Text(_opLabel(item.operation))),
                                  DataCell(Text(
                                    item.recordId.length > 8
                                        ? '...${item.recordId.substring(item.recordId.length - 8)}'
                                        : item.recordId,
                                    style: const TextStyle(fontSize: 12),
                                  )),
                                  DataCell(Chip(
                                    label: Text(_statusLabel(item.status)),
                                    backgroundColor: _statusColor(item.status)
                                        .withValues(alpha: 0.15),
                                    labelStyle: TextStyle(
                                        color: _statusColor(item.status),
                                        fontSize: 12),
                                  )),
                                  DataCell(Text('${item.attempts}')),
                                  DataCell(Text(
                                    item.errorMessage ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  )),
                                ]),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _tableLabel(String table) {
    switch (table) {
      case 'egg_production':
        return 'إنتاج البيض';
      case 'mortality':
        return 'النفوق';
      case 'feed_consumption':
        return 'استهلاك العلف';
      case 'feed_received':
        return 'استلام العلف';
      case 'egg_dispatch':
        return 'التخريج';
      case 'medications':
        return 'الأدوية';
      case 'customers':
        return 'الزبائن';
      case 'payments':
        return 'المدفوعات';
      case 'expenses':
        return 'المصروفات';
      case 'opening_balances':
        return 'الأرصدة الافتتاحية';
      case 'inventory_transactions':
        return 'المخزون';
      case 'flocks':
        return 'القطعان';
      default:
        return table;
    }
  }

  String _opLabel(SyncOperation op) {
    switch (op) {
      case SyncOperation.insert:
        return 'إضافة';
      case SyncOperation.update:
        return 'تعديل';
      case SyncOperation.delete:
        return 'حذف';
    }
  }

  String _statusLabel(SyncStatus status) {
    switch (status) {
      case SyncStatus.pending:
        return 'انتظار';
      case SyncStatus.synced:
        return 'مزامنة';
      case SyncStatus.failed:
        return 'فاشلة';
      case SyncStatus.conflict:
        return 'تعارض';
      case SyncStatus.processing:
        return 'قيد المعالجة';
    }
  }

  Color _statusColor(SyncStatus status) {
    switch (status) {
      case SyncStatus.pending:
        return AppStatusColors.warning(context);
      case SyncStatus.synced:
        return AppStatusColors.success(context);
      case SyncStatus.failed:
        return Theme.of(context).colorScheme.error;
      case SyncStatus.conflict:
        return AppStatusColors.danger(context);
      case SyncStatus.processing:
        return AppStatusColors.warning(context);
    }
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}