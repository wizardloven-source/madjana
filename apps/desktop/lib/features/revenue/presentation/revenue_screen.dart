import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

class RevenueScreen extends ConsumerStatefulWidget {
  const RevenueScreen({super.key});

  @override
  ConsumerState<RevenueScreen> createState() => _RevenueScreenState();
}

class _RevenueScreenState extends ConsumerState<RevenueScreen> {
  List<RevenueModel> _revenues = [];
  bool _loading = true;
  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _toDate = DateTime.now();
  RevenueCategory? _categoryFilter;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  double get _total => _revenues.fold(0, (s, r) => s + r.amount);

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final revenues = await ref.read(revenueRepositoryProvider).getRevenues(
            farmId: _farmId,
            fromDate: _fromDate,
            toDate: _toDate,
          );
      if (!mounted) return;
      setState(() {
        _revenues = _categoryFilter == null
            ? revenues
            : revenues.where((r) => r.category == _categoryFilter).toList();
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

  Future<void> _showRevenueDialog({RevenueModel? revenue}) async {
    final descCtrl = TextEditingController(text: revenue?.description ?? '');
    final amountCtrl = TextEditingController(
        text: revenue != null ? revenue.amount.toString() : '');
    final quantityCtrl = TextEditingController(
        text: revenue?.quantity != null ? revenue!.quantity.toString() : '');
    final unitPriceCtrl = TextEditingController();
    final areaCtrl = TextEditingController();
    var date = revenue?.date ?? DateTime.now();
    var category = revenue?.category ?? RevenueCategory.other;
    final defaultCurrency = revenue != null
        ? null
        : await ref.read(farmRepositoryProvider).getInputCurrency();
    var currency = revenue?.currency ?? defaultCurrency ?? AppCurrency.dollar;
    var exchangeRate = revenue?.exchangeRate;

    String? selectedFlockId = revenue?.referenceId;
    String? selectedInventoryItemId;
    String? selectedUnit = revenue?.unit ?? 'piece';

    List<FlockModel> flocks = [];
    List<InventoryItemModel> inventoryItems = [];

    if (category == RevenueCategory.liveChicken) {
      try {
        flocks = await ref.read(flockRepositoryProvider).getFlocks(_farmId);
      } catch (_) {}
    }
    if (category == RevenueCategory.equipment) {
      try {
        inventoryItems =
            await ref.read(inventoryRepositoryProvider).getItems(_farmId);
      } catch (_) {}
    }

    double toDollar(double value) =>
        currency == AppCurrency.lira && (exchangeRate ?? 0) > 0
            ? value / exchangeRate!
            : value;
    String inputSymbol(AppCurrency cu) => cu.symbol;

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(revenue == null ? 'إيراد جديد' : 'تعديل الإيراد'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<RevenueCategory>(
                    value: category,
                    decoration: const InputDecoration(labelText: 'نوع الإيراد'),
                    items: RevenueCategory.values
                        .map((c) => DropdownMenuItem(
                            value: c, child: Text(c.label)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) {
                        setDialog(() {
                          category = v;
                          selectedFlockId = null;
                          selectedInventoryItemId = null;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 12),
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
                  if (category == RevenueCategory.liveChicken) ...[
                    DropdownButtonFormField<String>(
                      value: selectedFlockId,
                      decoration:
                          const InputDecoration(labelText: 'القطيع'),
                      items: flocks
                          .map((f) => DropdownMenuItem(
                              value: f.id, child: Text(f.displayName)))
                          .toList(),
                      onChanged: (v) =>
                          setDialog(() => selectedFlockId = v),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: quantityCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'عدد الدجاج المباع'),
                      onChanged: (_) => setDialog(() {}),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: unitPriceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: InputDecoration(
                          labelText:
                              'سعر الطائر الواحد (${inputSymbol(currency)})'),
                      onChanged: (_) => setDialog(() {}),
                    ),
                    const SizedBox(height: 8),
                    if ((double.tryParse(quantityCtrl.text) ?? 0) > 0 &&
                        (double.tryParse(unitPriceCtrl.text) ?? 0) > 0)
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
                          'الإجمالي: ${Formatters.formatCurrency(double.parse(quantityCtrl.text.trim()) * double.parse(unitPriceCtrl.text.trim()))} ${inputSymbol(currency)} '
                          '(${quantityCtrl.text.trim()} × ${double.parse(unitPriceCtrl.text.trim()).toStringAsFixed(2)})',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                      ),
                  ] else if (category == RevenueCategory.building) ...[
                    TextField(
                      controller: areaCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'المساحة (م²)'),
                      onChanged: (_) => setDialog(() {}),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: unitPriceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: InputDecoration(
                          labelText:
                              'سعر المتر المربع (${inputSymbol(currency)})'),
                      onChanged: (_) => setDialog(() {}),
                    ),
                    const SizedBox(height: 8),
                    if ((double.tryParse(areaCtrl.text) ?? 0) > 0 &&
                        (double.tryParse(unitPriceCtrl.text) ?? 0) > 0)
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
                          'الإجمالي: ${Formatters.formatCurrency(double.parse(areaCtrl.text.trim()) * double.parse(unitPriceCtrl.text.trim()))} ${inputSymbol(currency)} '
                          '(${areaCtrl.text.trim()} م² × ${double.parse(unitPriceCtrl.text.trim()).toStringAsFixed(2)})',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                      ),
                  ] else if (category == RevenueCategory.equipment) ...[
                    DropdownButtonFormField<String>(
                      value: selectedInventoryItemId,
                      decoration:
                          const InputDecoration(labelText: 'عنصر المخزون'),
                      items: inventoryItems
                          .where((i) => i.quantity > 0)
                          .map((i) => DropdownMenuItem(
                              value: i.id,
                              child: Text(
                                  '${i.name} (متوفر: ${i.quantity} ${i.unit.label})')))
                          .toList(),
                      onChanged: (v) =>
                          setDialog(() => selectedInventoryItemId = v),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: quantityCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'الكمية المباعة'),
                      onChanged: (_) => setDialog(() {}),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: selectedUnit,
                      decoration:
                          const InputDecoration(labelText: 'الوحدة'),
                      items: InventoryUnit.values
                          .map((u) => DropdownMenuItem(
                              value: u.name, child: Text(u.label)))
                          .toList(),
                      onChanged: (v) =>
                          setDialog(() => selectedUnit = v),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: unitPriceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: InputDecoration(
                          labelText:
                              'سعر الوحدة (${inputSymbol(currency)})'),
                      onChanged: (_) => setDialog(() {}),
                    ),
                    const SizedBox(height: 8),
                    if ((double.tryParse(quantityCtrl.text) ?? 0) > 0 &&
                        (double.tryParse(unitPriceCtrl.text) ?? 0) > 0)
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
                          'الإجمالي: ${Formatters.formatCurrency(double.parse(quantityCtrl.text.trim()) * double.parse(unitPriceCtrl.text.trim()))} ${inputSymbol(currency)} '
                          '(${quantityCtrl.text.trim()} × ${double.parse(unitPriceCtrl.text.trim()).toStringAsFixed(2)})',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                      ),
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
                      double.tryParse(amountCtrl.text) != null &&
                      amountCtrl.text.isNotEmpty)
                    Text(
                      'ما يقابلها بالدولار: ${Formatters.formatCurrency(toDollar(double.parse(amountCtrl.text.trim())))}',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey),
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
                        if (picked != null)
                          setDialog(() => date = picked);
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
                if (category == RevenueCategory.liveChicken) {
                  final qty = double.tryParse(quantityCtrl.text.trim());
                  final price = double.tryParse(unitPriceCtrl.text.trim());
                  if (qty == null ||
                      qty <= 0 ||
                      price == null ||
                      price <= 0 ||
                      selectedFlockId == null) {
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                        content: Text(
                            'اختر القطيع وأدخل العدد والسعر بشكل صحيح')));
                    return;
                  }
                  final flock = flocks.firstWhere(
                      (f) => f.id == selectedFlockId,
                      orElse: () => flocks.first);
                  if (qty > flock.currentCount) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                        content: Text(
                            'العدد المباع ($qty) يتجاوز العدد المتوفر (${flock.currentCount})')));
                    return;
                  }
                  amountCtrl.text =
                      (qty * price).toStringAsFixed(2);
                } else if (category == RevenueCategory.building) {
                  final area = double.tryParse(areaCtrl.text.trim());
                  final price = double.tryParse(unitPriceCtrl.text.trim());
                  if (area == null || area <= 0 || price == null || price <= 0) {
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                        content: Text('أدخل المساحة والسعر بشكل صحيح')));
                    return;
                  }
                  amountCtrl.text =
                      (area * price).toStringAsFixed(2);
                } else if (category == RevenueCategory.equipment) {
                  final qty = double.tryParse(quantityCtrl.text.trim());
                  final price = double.tryParse(unitPriceCtrl.text.trim());
                  if (qty == null ||
                      qty <= 0 ||
                      price == null ||
                      price <= 0 ||
                      selectedInventoryItemId == null) {
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                        content: Text(
                            'اختر العنصر وأدخل الكمية والسعر بشكل صحيح')));
                    return;
                  }
                  final item = inventoryItems.firstWhere(
                      (i) => i.id == selectedInventoryItemId,
                      orElse: () => inventoryItems.first);
                  if (qty > item.quantity) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                        content: Text(
                            'الكمية المباعة ($qty) تتجاوز الكمية المتوفرة (${item.quantity})')));
                    return;
                  }
                  amountCtrl.text =
                      (qty * price).toStringAsFixed(2);
                }
                final rawAmount = double.tryParse(amountCtrl.text.trim());
                if (rawAmount == null || rawAmount <= 0) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('أدخل مبلغاً صحيحاً')));
                  return;
                }
                if (currency == AppCurrency.lira &&
                    (exchangeRate ?? 0) <= 0) {
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
      final amount = double.parse(amountCtrl.text.trim());
      final quantity = double.tryParse(quantityCtrl.text.trim());
      final workerId = ref.read(authProvider).currentUser?.uid;

      await ref.read(revenueRepositoryProvider).save(RevenueModel(
            id: revenue?.id,
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
            quantity: quantity,
            unit: selectedUnit,
            referenceId: category == RevenueCategory.liveChicken
                ? selectedFlockId
                : category == RevenueCategory.equipment
                    ? selectedInventoryItemId
                    : null,
            workerId: workerId,
          ));

      if (category == RevenueCategory.liveChicken &&
          selectedFlockId != null &&
          quantity != null) {
        try {
          final flock = flocks.firstWhere((f) => f.id == selectedFlockId);
          final newCount = flock.currentCount - quantity.toInt();
          await ref.read(flockRepositoryProvider).updateFlock(
                FlockModel(
                  id: flock.id,
                  farmId: flock.farmId,
                  breed: flock.breed,
                  startDate: flock.startDate,
                  initialCount: flock.initialCount,
                  currentCount: newCount < 0 ? 0 : newCount,
                  status: flock.status,
                  sectionsCount: flock.sectionsCount,
                  version: flock.version,
                ),
              );
        } catch (_) {}
      }

      if (category == RevenueCategory.equipment &&
          selectedInventoryItemId != null &&
          quantity != null) {
        try {
          await ref
              .read(inventoryRepositoryProvider)
              .adjustStock(
                itemId: selectedInventoryItemId!,
                isInput: false,
                quantity: quantity,
                note: 'بيع عبر الإيرادات',
              );
        } catch (_) {}
      }

      _load();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _delete(RevenueModel revenue) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الإيراد'),
        content: Text(
            'حذف إيراد "${revenue.category.label}" بقيمة ${revenue.amount}؟'),
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
    if (ok != true || revenue.id == null) return;
    try {
      await ref.read(revenueRepositoryProvider).delete(revenue.id!);
      _load();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _exportCsv() async {
    if (_revenues.isEmpty) return;
    final buffer = StringBuffer();
    buffer.writeln('التاريخ,الفئة,الوصف,المبلغ,العملة,الكمية,الوحدة');
    for (final r in _revenues) {
      buffer.writeln(
        '${DateFormat('yyyy/MM/dd').format(r.date)},'
        '${r.category.label},'
        '${r.description ?? ''},'
        '${r.amount},'
        '${r.currency.symbol},'
        '${r.quantity ?? ''},'
        '${r.unit ?? ''}',
      );
    }
    final fileName =
        'revenue_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv';
    final file = File(fileName);
    await file.writeAsString(buffer.toString());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تم تصدير الملف: $fileName')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currency = ref.watch(currencyProvider).value ?? '';

    final byCategory = <RevenueCategory, double>{};
    for (final r in _revenues) {
      byCategory[r.category] = (byCategory[r.category] ?? 0) + r.amount;
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
                  child: Text(
                      'من: ${DateFormat('yyyy/MM/dd').format(_fromDate)}'),
                ),
                OutlinedButton(
                  onPressed: () => _pickDate(isFrom: false),
                  child: Text(
                      'إلى: ${DateFormat('yyyy/MM/dd').format(_toDate)}'),
                ),
                DropdownButton<RevenueCategory?>(
                  hint: const Text('كل الفئات'),
                  value: _categoryFilter,
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('كل الفئات')),
                    ...RevenueCategory.values.map((c) =>
                        DropdownMenuItem(
                            value: c, child: Text(c.label))),
                  ],
                  onChanged: (v) {
                    setState(() => _categoryFilter = v);
                    _load();
                  },
                ),
              ]),
              Wrap(spacing: 8, children: [
                FilledButton.icon(
                  onPressed: () => _showRevenueDialog(),
                  icon: const Icon(Icons.add),
                  label: const Text('إيراد جديد'),
                ),
                OutlinedButton.icon(
                  onPressed: _exportCsv,
                  icon: const Icon(Icons.file_download_outlined),
                  label: const Text('تصدير CSV'),
                ),
              ]),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              Builder(builder: (context) {
                final isDark =
                    Theme.of(context).brightness == Brightness.dark;
                return Chip(
                  label: Text(
                    'الإجمالي: ${NumberFormat('#,##0.##').format(_total)} $currency',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: isDark
                          ? const Color(0xFFFFEB3B)
                          : Colors.green.shade700,
                    ),
                  ),
                  backgroundColor:
                      isDark ? Colors.black : Colors.white,
                  side: BorderSide(
                    color: isDark
                        ? const Color(0xFFFFEB3B)
                        : Colors.green.shade300,
                  ),
                );
              }),
              Chip(label: Text('عدد السجلات: ${_revenues.length}')),
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
          else if (_revenues.isEmpty)
            const Expanded(child: Center(child: Text('لا توجد إيرادات')))
          else
            Expanded(
              child: SingleChildScrollView(
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('التاريخ')),
                    DataColumn(label: Text('الفئة')),
                    DataColumn(label: Text('الوصف')),
                    DataColumn(label: Text('الكمية')),
                    DataColumn(label: Text('المبلغ')),
                    DataColumn(label: Text('إجراءات')),
                  ],
                  rows: _revenues.map((r) {
                    return DataRow(cells: [
                      DataCell(Text(
                          DateFormat('yyyy/MM/dd').format(r.date))),
                      DataCell(Text(r.category.label)),
                      DataCell(Text(r.description ?? '-')),
                      DataCell(Text(r.quantity != null
                          ? '${Formatters.formatNumber(r.quantity!)} ${r.unit ?? ''}'
                          : '-')),
                      DataCell(Text(
                          '${NumberFormat('#,##0.##').format(r.amount)} $currency')),
                      DataCell(Row(children: [
                        IconButton(
                          tooltip: 'تعديل',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () =>
                              _showRevenueDialog(revenue: r),
                        ),
                        IconButton(
                          tooltip: 'حذف',
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          onPressed: () => _delete(r),
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
