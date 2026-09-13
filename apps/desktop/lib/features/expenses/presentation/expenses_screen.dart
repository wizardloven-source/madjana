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
    final bundlesCtrl = TextEditingController(
        text: expense?.cartonBundles?.toString() ?? '');
    // عند التعديل نُعاد حساب سعر الربطة من الإجمالي المخزّن
    final priceCtrl = TextEditingController(
      text: (expense != null &&
              expense.category == ExpenseCategory.carton &&
              expense.cartonBundles != null &&
              expense.cartonBundles! > 0)
          ? (expense.amount / expense.cartonBundles!).toStringAsFixed(4)
          : '',
    );
    var date = expense?.date ?? DateTime.now();
    var category = expense?.category ?? ExpenseCategory.other;
    final defaultCurrency = expense != null
        ? null
        : await ref.read(farmRepositoryProvider).getInputCurrency();
    var currency = expense?.currency ?? defaultCurrency ?? AppCurrency.dollar;
    var exchangeRate = expense?.exchangeRate;

    // لتحويل الليرة → دولار عند الحفظ (المخزّن بالدولار دائماً)
    double toDollar(double value) =>
        currency == AppCurrency.lira && (exchangeRate ?? 0) > 0
            ? value / exchangeRate!
            : value;
    String inputSymbol(AppCurrency cu) => cu.symbol;

    // الإجمالي المحسوب ديناميكياً للكرتون: سعر الربطة × عدد الربطات
    double cartonTotal(String bundlesText, String priceText) {
      final b = int.tryParse(bundlesText.trim());
      final p = double.tryParse(priceText.trim());
      if (b == null || p == null || b <= 0 || p <= 0) return 0;
      return p * b;
    }

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(expense == null ? 'مصروف جديد' : 'تعديل المصروف'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<ExpenseCategory>(
                    value: category,
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
                  // ─── عملة الإدخال ───
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final c in AppCurrency.values)
                        ChoiceChip(
                          label: Text('${c.label} (${c.symbol})'),
                          selected: currency == c,
                          onSelected: (_) => setDialog(() => currency = c),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // ─── سعر الصرف عند الإدخال بالليرة ───
                  if (currency == AppCurrency.lira) ...[
                    TextField(
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'سعر صرف (ليرة لكل 1 دولار)'),
                      onChanged: (v) {
                        final r = double.tryParse(v.trim());
                        setDialog(() => exchangeRate = r);
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  // ─── شراء صحون الكرتون: عدد الربطات × سعر الربطة = الإجمالي ديناميكياً ───
                  if (category == ExpenseCategory.carton) ...[
                    TextField(
                      controller: bundlesCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'عدد الربطات (الربطة = 100 صحن)'),
                      onChanged: (_) => setDialog(() {}),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: priceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: InputDecoration(
                          labelText: 'سعر الربطة الواحدة (${inputSymbol(currency)})'),
                      onChanged: (_) => setDialog(() {}),
                    ),
                    const SizedBox(height: 8),
                    if (cartonTotal(bundlesCtrl.text, priceCtrl.text) > 0)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.green.withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          'الإجمالي: ${Formatters.formatCurrency(cartonTotal(bundlesCtrl.text, priceCtrl.text))} ${inputSymbol(currency)} '
                          '(${bundlesCtrl.text.trim()} × ${double.parse(priceCtrl.text.trim()).toStringAsFixed(2)})',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                      ),
                    const SizedBox(height: 8),
                  ] else ...[
                    TextField(
                      controller: amountCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: InputDecoration(
                          labelText: 'المبلغ (${inputSymbol(currency)})'),
                      onChanged: (_) => setDialog(() {}),
                    ),
                  ],
                  if (currency == AppCurrency.lira &&
                      category == ExpenseCategory.carton &&
                      cartonTotal(bundlesCtrl.text, priceCtrl.text) > 0)
                    Text(
                      'ما يقابلها بالدولار: ${Formatters.formatCurrency(toDollar(cartonTotal(bundlesCtrl.text, priceCtrl.text)))}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  if (currency == AppCurrency.lira &&
                      category != ExpenseCategory.carton &&
                      double.tryParse(amountCtrl.text) != null)
                    Text(
                      'ما يقابلها بالدولار: ${Formatters.formatCurrency(toDollar(double.parse(amountCtrl.text.trim())))}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
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
                      child: Text(
                          'التاريخ: ${DateFormat('yyyy/MM/dd').format(date)}'),
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
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                final isCartonOnSave = category == ExpenseCategory.carton;
                final rawValue = isCartonOnSave
                    ? cartonTotal(bundlesCtrl.text, priceCtrl.text)
                    : double.tryParse(amountCtrl.text.trim());
                if (rawValue == null || rawValue <= 0 ||
                    (isCartonOnSave && int.tryParse(bundlesCtrl.text) == null)) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                      content: Text(isCartonOnSave
                          ? 'أدخل عدد الربطات وسعر الربطة'
                          : 'أدخل مبلغاً صحيحاً')));
                  return;
                }
                if (currency == AppCurrency.lira && (exchangeRate ?? 0) <= 0) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                      content: Text('أدخل سعر صرف صحيحاً لليرة')));
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
      final isCartonOnSave = category == ExpenseCategory.carton;
      final amount = isCartonOnSave
          ? cartonTotal(bundlesCtrl.text, priceCtrl.text)
          : double.parse(amountCtrl.text.trim());
      final cartonBundles = isCartonOnSave
          ? int.parse(bundlesCtrl.text.trim())
          : null;
      await ref.read(expenseRepositoryProvider).save(ExpenseModel(
            id: expense?.id,
            farmId: _farmId,
            date: date,
            category: category,
            description: descCtrl.text.trim().isEmpty
                ? null
                : descCtrl.text.trim(),
            amount: toDollar(amount),
            currency: currency,
            exchangeRate:
                currency == AppCurrency.lira ? exchangeRate : null,
            cartonBundles: cartonBundles,
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
              Builder(builder: (context) {
                final isDark =
                    Theme.of(context).brightness == Brightness.dark;
                // ليلاً: خلفية سوداء داكنة بنص أصفر لامع / نهاراً: أبيض بنص أحمر
                return Chip(
                  label: Text(
                    'الإجمالي: ${NumberFormat('#,##0.##').format(_total)} $currency',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: isDark
                          ? const Color(0xFFFFEB3B)
                          : Colors.red.shade700,
                    ),
                  ),
                  backgroundColor: isDark
                      ? Colors.black
                      : Colors.white,
                  side: BorderSide(
                    color: isDark
                        ? const Color(0xFFFFEB3B)
                        : Colors.red.shade300,
                  ),
                );
              }),
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
                    final isCarton = e.category == ExpenseCategory.carton &&
                        e.cartonBundles != null;
                    return DataRow(cells: [
                      DataCell(Text(DateFormat('yyyy/MM/dd').format(e.date))),
                      DataCell(Text(e.category.label)),
                      DataCell(Text(
                          isCarton
                              ? '${e.cartonBundles} ربطة × سعر (${(e.amount / e.cartonBundles!).toStringAsFixed(2)})'
                              : (e.description ?? '-'))),
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
