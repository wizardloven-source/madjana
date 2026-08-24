import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة المصروفات التشغيلية - للمدير
class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  List<ExpenseModel> _expenses = [];
  bool _loading = true;
  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _toDate = DateTime.now();
  ExpenseCategory? _categoryFilter;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  double get _total => _expenses.fold(0, (s, e) => s + e.amount);

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final expenses = await ref.read(expenseRepositoryProvider).getExpenses(
            farmId: _farmId,
            fromDate: _fromDate,
            toDate: _toDate,
          );
      if (!mounted) return;
      setState(() {
        _expenses = _categoryFilter == null
            ? expenses
            : expenses.where((e) => e.category == _categoryFilter).toList();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
    );
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _fromDate : _toDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() {
        if (isFrom) {
          _fromDate = picked;
        } else {
          _toDate = picked;
        }
      });
      _load();
    }
  }

  Future<void> _showExpenseDialog({ExpenseModel? expense}) async {
    final amountCtrl = TextEditingController(
        text: expense != null ? expense.amount.toString() : '');
    final descCtrl = TextEditingController(text: expense?.description ?? '');
    var date = expense?.date ?? DateTime.now();
    var category = expense?.category ?? ExpenseCategory.other;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(expense == null ? 'مصروف جديد' : 'تعديل المصروف'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<ExpenseCategory>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'الفئة'),
                  items: ExpenseCategory.values
                      .map((c) => DropdownMenuItem(
                          value: c, child: Text(c.label)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDialog(() => category = v);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'المبلغ'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descCtrl,
                  decoration:
                      const InputDecoration(labelText: 'الوصف (اختياري)'),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: Text('التاريخ: ${DateFormat('yyyy/MM/dd').format(date)}'),
                  ),
                  TextButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: date,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) setDialog(() => date = picked);
                    },
                    child: const Text('تغيير'),
                  ),
                ]),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (double.tryParse(amountCtrl.text.trim()) == null ||
                    double.parse(amountCtrl.text.trim()) <= 0) {
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    try {
      await ref.read(expenseRepositoryProvider).save(ExpenseModel(
            id: expense?.id,
            farmId: _farmId,
            date: date,
            category: category,
            description: descCtrl.text.trim().isEmpty
                ? null
                : descCtrl.text.trim(),
            amount: double.parse(amountCtrl.text.trim()),
          ));
      _load();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _delete(ExpenseModel expense) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف المصروف'),
        content: Text('حذف مصروف "${expense.category.label}" بقيمة ${expense.amount}؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (ok != true || expense.id == null) return;
    try {
      await ref.read(expenseRepositoryProvider).delete(expense.id!);
      _load();
    } catch (e) {
      _error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = ref.watch(currencyProvider).value ?? '';

    // توزيع المصروفات حسب الفئة
    final byCategory = <ExpenseCategory, double>{};
    for (final e in _expenses) {
      byCategory[e.category] = (byCategory[e.category] ?? 0) + e.amount;
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Wrap(spacing: 8, children: [
                OutlinedButton(
                  onPressed: () => _pickDate(isFrom: true),
                  child: Text('من: ${DateFormat('yyyy/MM/dd').format(_fromDate)}'),
                ),
                OutlinedButton(
                  onPressed: () => _pickDate(isFrom: false),
                  child: Text('إلى: ${DateFormat('yyyy/MM/dd').format(_toDate)}'),
                ),
                DropdownButton<ExpenseCategory?>(
                  hint: const Text('كل الفئات'),
                  value: _categoryFilter,
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('كل الفئات')),
                    ...ExpenseCategory.values.map((c) =>
                        DropdownMenuItem(value: c, child: Text(c.label))),
                  ],
                  onChanged: (v) {
                    setState(() => _categoryFilter = v);
                    _load();
                  },
                ),
              ]),
              FilledButton.icon(
                onPressed: () => _showExpenseDialog(),
                icon: const Icon(Icons.add),
                label: const Text('مصروف جديد'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              Chip(
                label: Text(
                    'الإجمالي: ${NumberFormat('#,##0.##').format(_total)} $currency'),
                backgroundColor: Colors.orange.shade100,
              ),
              Chip(label: Text('عدد السجلات: ${_expenses.length}')),
              ...byCategory.entries.map((e) => Chip(
                    label: Text(
                        '${e.key.label}: ${NumberFormat('#,##0.##').format(e.value)}'),
                  )),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Expanded(
                child: Center(child: CircularProgressIndicator()))
          else if (_expenses.isEmpty)
            const Expanded(child: Center(child: Text('لا توجد مصروفات')))
          else
            Expanded(
              child: SingleChildScrollView(
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('التاريخ')),
                    DataColumn(label: Text('الفئة')),
                    DataColumn(label: Text('الوصف')),
                    DataColumn(label: Text('المبلغ')),
                    DataColumn(label: Text('إجراءات')),
                  ],
                  rows: _expenses.map((e) {
                    return DataRow(cells: [
                      DataCell(Text(DateFormat('yyyy/MM/dd').format(e.date))),
                      DataCell(Text(e.category.label)),
                      DataCell(Text(e.description ?? '-')),
                      DataCell(Text(
                          '${NumberFormat('#,##0.##').format(e.amount)} $currency')),
                      DataCell(Row(children: [
                        IconButton(
                          tooltip: 'تعديل',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _showExpenseDialog(expense: e),
                        ),
                        IconButton(
                          tooltip: 'حذف',
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          onPressed: () => _delete(e),
                        ),
                      ])),
                    ]);
                  }).toList(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
