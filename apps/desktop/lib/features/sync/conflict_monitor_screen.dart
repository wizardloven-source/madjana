import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// شاشة مراقبة وحل تعارضات المزامنة
/// متاحة فقط للمديرين
class ConflictMonitorScreen extends ConsumerStatefulWidget {
  const ConflictMonitorScreen({super.key});

  @override
  ConsumerState<ConflictMonitorScreen> createState() =>
      _ConflictMonitorScreenState();
}

class _ConflictMonitorScreenState extends ConsumerState<ConflictMonitorScreen> {
  bool _isLoading = true;
  List<ConflictModel> _conflicts = [];
  String? _error;
  String? _selectedTable;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _loadConflicts();
  }

  Future<void> _loadConflicts() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final conflictRepo = ref.read(conflictRepositoryProvider);
      final conflicts = await conflictRepo.getAllConflicts(
        tableName: _selectedTable,
        status: 'pending',
      );
      setState(() {
        _conflicts = conflicts;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'فشل تحميل التعارضات: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _resolveConflict(String conflictId, String resolution) async {
    setState(() => _resolving = true);
    try {
      final conflictRepo = ref.read(conflictRepositoryProvider);
      final syncRepo = ref.read(syncRepositoryProvider);

      if (resolution == 'merge') {
        // P0-05: Merge resolution — apply server data as base
        final conflict =
            await conflictRepo.getConflictById(conflictId);
        if (conflict != null && conflict.serverData != null) {
          await syncRepo.queueChange(
            SyncChangeModel(
              farmId: conflict.serverData!['farm_id'] as String? ?? '',
              tableName: conflict.tableName,
              recordId: conflict.recordId,
              operation: SyncOperation.update,
              changedAt: DateTime.now(),
              userId: conflict.serverData!['worker_id'] as String?,
              payload: conflict.serverData!,
            ),
          );
        }
        await conflictRepo.resolveConflict(conflictId, resolution: resolution);
      } else if (resolution == 'client_wins') {
        final conflict =
            await conflictRepo.getConflictById(conflictId);
        if (conflict != null) {
          await syncRepo.queueChange(
            SyncChangeModel(
              farmId: conflict.clientData['farm_id'] as String? ?? '',
              tableName: conflict.tableName,
              recordId: conflict.recordId,
              operation: SyncOperation.update,
              changedAt: DateTime.now(),
              userId: (conflict.clientData['worker_id'] ??
                      conflict.clientData['created_by']) as String?,
              payload: conflict.clientData,
            ),
          );
        }
        await conflictRepo.resolveConflict(conflictId, resolution: resolution);
      } else {
        // server_wins or ignore
        if (resolution == 'server_wins') {
          final conflict =
              await conflictRepo.getConflictById(conflictId);
          if (conflict != null && conflict.serverData != null) {
            await syncRepo.queueChange(
              SyncChangeModel(
                farmId: conflict.serverData!['farm_id'] as String? ?? '',
                tableName: conflict.tableName,
                recordId: conflict.recordId,
                operation: SyncOperation.update,
                changedAt: DateTime.now(),
                userId: conflict.serverData!['worker_id'] as String?,
                payload: conflict.serverData!,
              ),
            );
          }
          await conflictRepo.resolveConflict(conflictId,
              resolution: resolution);
        } else {
          await conflictRepo.ignoreConflict(conflictId);
        }
      }

      await _loadConflicts();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تم حل التعارض بنجاح'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('فشل حل التعارض: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تعارضات المزامنة'),
        actions: [
          PopupMenuButton<String?>(
            icon: const Icon(Icons.filter_list),
            onSelected: (table) {
              setState(() => _selectedTable = table);
              _loadConflicts();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: null, child: Text('الكل')),
              ...['egg_production', 'mortality', 'feed_consumption',
                      'feed_received', 'egg_dispatch', 'medications',
                      'payments', 'expenses', 'customers', 'inventory_items']
                  .map((t) => PopupMenuItem(value: t, child: Text(t))),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadConflicts,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _conflicts.isEmpty
                  ? _buildEmpty()
                  : _buildConflictList(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 64, color: Colors.red),
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadConflicts,
            icon: const Icon(Icons.refresh),
            label: const Text('إعادة المحاولة'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline,
              size: 64, color: Colors.green.shade400),
          const SizedBox(height: 16),
          const Text(
            'لا توجد تعارضات معلقة',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'جميع البيانات متزامنة بنجاح',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildConflictList() {
    return RefreshIndicator(
      onRefresh: _loadConflicts,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _conflicts.length,
        itemBuilder: (context, index) {
          final conflict = _conflicts[index];
          return _ConflictCard(
            conflict: conflict,
            resolving: _resolving,
            onResolve: _resolveConflict,
          );
        },
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  final ConflictModel conflict;
  final bool resolving;
  final Function(String, String) onResolve;

  const _ConflictCard({
    required this.conflict,
    required this.resolving,
    required this.onResolve,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.sync_problem, color: cs.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${conflict.tableName} — ${conflict.recordId.substring(0, 8)}...',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                _StatusChip(status: conflict.status),
              ],
            ),
            const Divider(height: 24),

            // Data comparison
            if (conflict.clientData.isNotEmpty) ...[
              const Text('بيانات الجهاز:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                _formatData(conflict.clientData),
                style: TextStyle(
                    fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
            ],
            if (conflict.serverData != null) ...[
              const Text('بيانات السيرفر:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                _formatData(conflict.serverData!),
                style: TextStyle(
                    fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
            ],

            // Action buttons
            if (conflict.status == 'pending')
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: resolving
                        ? null
                        : () => onResolve(conflict.id, 'client_wins'),
                    icon: const Icon(Icons.phone_android, size: 16),
                    label: const Text('بيانات الجهاز'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: resolving
                        ? null
                        : () => onResolve(conflict.id, 'server_wins'),
                    icon: const Icon(Icons.cloud, size: 16),
                    label: const Text('بيانات السيرفر'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: resolving
                        ? null
                        : () => onResolve(conflict.id, 'ignore'),
                    icon: const Icon(Icons.remove_circle_outline, size: 16),
                    label: const Text('تجاهل'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  String _formatData(Map<String, dynamic> data) {
    final important = [
      'farm_id', 'flock_id', 'date', 'total_eggs',
      'count', 'quantity_kg', 'amount', 'medicine_name',
    ];
    final entries = data.entries
        .where((e) => important.contains(e.key) || e.key == 'id')
        .take(5)
        .map((e) => '${e.key}: ${e.value}')
        .join('\n');
    return entries.isEmpty ? '...' : entries;
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    switch (status) {
      case 'resolved':
        color = Colors.green;
        label = 'تم الحل';
        break;
      case 'ignored':
        color = Colors.grey;
        label = 'تم تجاهله';
        break;
      default:
        color = Colors.orange;
        label = 'معلق';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, color: color)),
    );
  }
}
