import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/providers.dart';
import '../../../core/shell_state.dart';

/// شاشة طلبات الموافقة:
/// - العامل عندما يحاول تخريج كمية أكبر من المخزون يرسل طلباً
/// - المدير يعتمد أو يرفض الطلب من هنا
class ApprovalsScreen extends ConsumerStatefulWidget {
  const ApprovalsScreen({super.key});

  @override
  ConsumerState<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

class _ApprovalsScreenState extends ConsumerState<ApprovalsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _requests = [];
  bool _showAll = false;
  Timer? _autoRefresh;

  @override
  void initState() {
    super.initState();
    _load();
    // تحديث تلقائي كل 30 ثانية لالتقاط طلبات العمال الجديدة
    _autoRefresh = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) setState(() => _loading = true);

    try {
      var query = ref.read(supabaseClientProvider).from('dispatch_requests').select();

      if (!_showAll) {
        query = query.eq('status', 'pending');
      }

      final rows = await query.order('created_at', ascending: false).limit(200);
      _requests = ((rows as List).cast<Map<String, dynamic>>())
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      _requests = [];
    }

    // تحديث شارة العدّاد في شريط التنقل (دائماً بعدّاد المعلقة)
    try {
      final pendingRows = await ref
          .read(supabaseClientProvider)
          .from('dispatch_requests')
          .select('id')
          .eq('status', 'pending');
      ref.read(pendingApprovalsProvider.notifier).state =
          (pendingRows as List).length;
    } catch (_) {}

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _decide(Map<String, dynamic> request, String status) async {
    try {
      await ref.read(supabaseClientProvider).from('dispatch_requests').update({
        'status': status,
        'decided_at': DateTime.now().toIso8601String(),
      }).eq('id', request['id'] as String);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(status == 'approved'
              ? 'تمت الموافقة — يمكن للعامل التخريج الآن'
              : 'تم رفض الطلب'),
        ));
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل التحديث: $e')),
        );
      }
    }
  }

  Color _statusColor(String? status) {
    switch (status) {
      case 'approved':
        return Colors.green.shade700;
      case 'rejected':
        return Theme.of(context).colorScheme.error;
      default:
        return Colors.orange.shade800;
    }
  }

  String _statusLabel(String? status) {
    switch (status) {
      case 'approved':
        return 'معتمد';
      case 'rejected':
        return 'مرفوض';
      default:
        return 'بانتظار المراجعة';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final dateFormat = DateFormat('yyyy/MM/dd HH:mm');
    final pendingCount =
        _requests.where((r) => r['status'] == 'pending').length;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.approval,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                pendingCount > 0
                    ? 'طلبات التخريج ($pendingCount بانتظارك)'
                    : 'طلبات التخريج',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              FilterChip(
                label: const Text('عرض الكل'),
                selected: _showAll,
                onSelected: (v) {
                  _showAll = v;
                  _load();
                },
              ),
              IconButton(
                tooltip: 'تحديث',
                icon: const Icon(Icons.refresh),
                onPressed: _load,
              ),
            ],
          ),
          const SizedBox(height: 12),

          Expanded(
            child: _requests.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_outline,
                            size: 56, color: Colors.grey[400]),
                        const SizedBox(height: 12),
                        Text(_showAll
                            ? 'لا توجد طلبات'
                            : 'لا توجد طلبات معلقة'),
                      ],
                    ),
                  )
                : Card(
                    elevation: 2,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.vertical,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('التاريخ')),
                            DataColumn(label: Text('الكمية المطلوبة')),
                            DataColumn(label: Text('المخزون وقت الطلب')),
                            DataColumn(label: Text('الفرق')),
                            DataColumn(label: Text('الحالة')),
                            DataColumn(label: Text('إجراء')),
                          ],
                          rows: _requests.map((request) {
                            final totalEggs =
                                (request['total_eggs'] as num?)?.toInt() ?? 0;
                            final stockEggs =
                                (request['stock_eggs'] as num?)?.toInt() ?? 0;

                            return DataRow(
                              cells: [
                                DataCell(Text(dateFormat.format(
                                    DateTime.tryParse(
                                            request['created_at']
                                                    ?.toString() ??
                                                '') ??
                                        DateTime.now()))),
                                DataCell(Text('$totalEggs بيضة')),
                                DataCell(Text('$stockEggs بيضة')),
                                DataCell(Text(
                                  '+${totalEggs - stockEggs}',
                                  style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )),
                                DataCell(Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _statusColor(request['status'])
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    _statusLabel(request['status']),
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color:
                                          _statusColor(request['status']),
                                    ),
                                  ),
                                )),
                                DataCell(
                                  request['status'] == 'pending'
                                      ? Row(
                                          children: [
                                            FilledButton.icon(
                                              style: FilledButton.styleFrom(
                                                backgroundColor:
                                                    Colors.green.shade700,
                                              ),
                                              icon: const Icon(Icons.check,
                                                  size: 18),
                                              label: const Text('اعتماد'),
                                              onPressed: () =>
                                                  _decide(request, 'approved'),
                                            ),
                                            const SizedBox(width: 8),
                                            OutlinedButton.icon(
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: Theme.of(
                                                        context)
                                                    .colorScheme
                                                    .error,
                                              ),
                                              icon: const Icon(Icons.close,
                                                  size: 18),
                                              label: const Text('رفض'),
                                              onPressed: () =>
                                                  _decide(request, 'rejected'),
                                            ),
                                          ],
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
