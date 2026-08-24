import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../providers/worker_providers.dart';
import 'salary_slip_screen.dart';
import 'advance_request_screen.dart';

/// شاشة رواتبي للعامل - تعرض كشوف الراتب وطلب سلفة
class MySalaryScreen extends ConsumerStatefulWidget {
  const MySalaryScreen({super.key});

  @override
  ConsumerState<MySalaryScreen> createState() => _MySalaryScreenState();
}

class _MySalaryScreenState extends ConsumerState<MySalaryScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final workerState = ref.watch(currentWorkerProvider);
    
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text('رواتبي'),
        centerTitle: true,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.account_balance_wallet), text: 'كشف الراتب'),
            Tab(icon: Icon(Icons.request_quote), text: 'طلب سلفة'),
          ],
        ),
      ),
      body: workerState.when(
        data: (worker) => TabBarView(
          controller: _tabController,
          children: [
            _buildSalarySlipsTab(worker),
            _buildAdvanceRequestsTab(worker),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text('حدث خطأ: $error', style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => ref.invalidate(currentWorkerProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCurrentMonthSlip(workerState.value),
        icon: const Icon(Icons.add),
        label: const Text('كشف هذا الشهر'),
        backgroundColor: Theme.of(context).primaryColor,
      ),
    );
  }

  Widget _buildSalarySlipsTab(WorkerModel? worker) {
    if (worker == null) {
      return const Center(child: Text('لا توجد بيانات عامل'));
    }

    final salarySlipsState = ref.watch(workerSalarySlipsProvider(worker.id));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(workerSalarySlipsProvider(worker.id)),
      child: salarySlipsState.when(
        data: (slips) {
          if (slips.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.receipt_long, size: 80, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    'لا توجد كشوف راتب',
                    style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'سيظهر كشف الراتب هنا عند إنشائه من قبل الإدارة',
                    style: TextStyle(color: Colors.grey[500]),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: slips.length,
            itemBuilder: (context, index) {
              final slip = slips[index];
              return _buildSalarySlipCard(slip);
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(child: Text('خطأ: $error')),
      ),
    );
  }

  Widget _buildSalarySlipCard(SalarySlipModel slip) {
    final isPaid = slip.isPaid;
    final monthName = _getMonthName(slip.month);
    
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: isPaid
                ? [Colors.green.shade50, Colors.green.shade100]
                : [Colors.orange.shade50, Colors.orange.shade100],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Chip(
                    avatar: Icon(
                      isPaid ? Icons.check_circle : Icons.pending,
                      size: 18,
                      color: isPaid ? Colors.green : Colors.orange,
                    ),
                    label: Text(isPaid ? 'تم الصرف' : 'غير مدفوع'),
                    backgroundColor: isPaid ? Colors.green : Colors.orange,
                    labelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '$monthName ${slip.year}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const Divider(height: 32),
              _buildDetailRow('الراتب الأساسي', '${slip.baseSalary.toStringAsFixed(2)}\$'),
              _buildDetailRow('المكافآت', '+${slip.bonuses.toStringAsFixed(2)}\$', positive: true),
              _buildDetailRow('السلف', '-${slip.advances.toStringAsFixed(2)}\$', negative: true),
              _buildDetailRow('الخصومات', '-${slip.deductions.toStringAsFixed(2)}\$', negative: true),
              const Divider(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('الصافي', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  Text(
                    '${slip.netSalary.toStringAsFixed(2)}\$',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: isPaid ? Colors.green.shade700 : Colors.orange.shade700,
                    ),
                  ),
                ],
              ),
              if (isPaid && slip.paidAt != null) ...[
                const SizedBox(height: 12),
                Text(
                  'تاريخ الصرف: ${_formatDate(slip.paidAt!)}',
                  style: TextStyle(color: Colors.grey[600], fontSize: 14),
                ),
              ],
              if (slip.notes != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.note_alt, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          slip.notes!,
                          style: TextStyle(color: Colors.grey[700]),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool positive = false, bool negative = false}) {
    Color? valueColor;
    if (positive) valueColor = Colors.green.shade700;
    if (negative) valueColor = Colors.red.shade700;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 16)),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvanceRequestsTab(WorkerModel worker) {
    final advanceRequestsState = ref.watch(workerAdvanceRequestsProvider(worker.id));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(workerAdvanceRequestsProvider(worker.id)),
      child: Column(
        children: [
          // زر طلب سلفة جديد
          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: () => _showAdvanceRequestDialog(worker),
              icon: const Icon(Icons.add),
              label: const Text('طلب سلفة جديدة'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          Expanded(
            child: advanceRequestsState.when(
              data: (requests) {
                if (requests.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.handshake, size: 80, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text(
                          'لا توجد طلبات سلفة',
                          style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: requests.length,
                  itemBuilder: (context, index) {
                    final request = requests[index];
                    return _buildAdvanceRequestCard(request);
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(child: Text('خطأ: $error')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvanceRequestCard(AdvanceRequestModel request) {
    final statusColor = _getStatusColor(request.status);
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(
          backgroundColor: statusColor.withOpacity(0.2),
          child: Icon(_getStatusIcon(request.status), color: statusColor),
        ),
        title: Text(
          '${request.amount.toStringAsFixed(2)}\$',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: statusColor,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text(request.reason),
            const SizedBox(height: 4),
            Text(
              'تاريخ الطلب: ${_formatDate(request.requestDate)}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        trailing: Chip(
          label: Text(request.status.label),
          backgroundColor: statusColor,
          labelStyle: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }

  void _showAdvanceRequestDialog(WorkerModel worker) {
    final amountController = TextEditingController();
    final reasonController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('طلب سلفة'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'المبلغ (\$)',
                    prefixIcon: Icon(Icons.attach_money),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) return 'الرجاء إدخال المبلغ';
                    if (double.tryParse(value) == null) return 'مبلغ غير صحيح';
                    if (double.parse(value) <= 0) return 'المبلغ يجب أن يكون أكبر من صفر';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: reasonController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'سبب السلفة',
                    prefixIcon: Icon(Icons.note),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) return 'الرجاء إدخال السبب';
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (formKey.currentState!.validate()) {
                final request = AdvanceRequestModel(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  workerId: worker.id,
                  workerName: worker.name,
                  amount: double.parse(amountController.text),
                  reason: reasonController.text,
                  requestDate: DateTime.now(),
                  createdAt: DateTime.now(),
                );

                try {
                  await ref.read(workerRepositoryProvider).requestAdvance(request);
                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('تم إرسال طلب السلفة بنجاح')),
                    );
                    ref.invalidate(workerAdvanceRequestsProvider(worker.id));
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('حدث خطأ: $e')),
                    );
                  }
                }
              }
            },
            child: const Text('إرسال الطلب'),
          ),
        ],
      ),
    );
  }

  void _showCurrentMonthSlip(WorkerModel? worker) {
    if (worker == null) return;
    
    final now = DateTime.now();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('كشف راتب هذا الشهر'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('هل تريد إنشاء كشف راتب لشهر ${_getMonthName(now.month)} $now؟'),
            const SizedBox(height: 16),
            const Text(
              'ملاحظة: هذه الميزة متاحة فقط للإدارة',
              style: TextStyle(color: Colors.orange, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }

  String _getMonthName(int month) {
    const months = [
      'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
      'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'
    ];
    return months[month - 1];
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  Color _getStatusColor(AdvanceRequestStatus status) {
    switch (status) {
      case AdvanceRequestStatus.pending:
        return Colors.orange;
      case AdvanceRequestStatus.approved:
        return Colors.blue;
      case AdvanceRequestStatus.rejected:
        return Colors.red;
      case AdvanceRequestStatus.paid:
        return Colors.green;
    }
  }

  IconData _getStatusIcon(AdvanceRequestStatus status) {
    switch (status) {
      case AdvanceRequestStatus.pending:
        return Icons.pending;
      case AdvanceRequestStatus.approved:
        return Icons.thumb_up;
      case AdvanceRequestStatus.rejected:
        return Icons.thumb_down;
      case AdvanceRequestStatus.paid:
        return Icons.check_circle;
    }
  }
}
