import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة إدارة المخزون (أدوية ومستلزمات) - للمدير
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  List<InventoryItemModel> _items = [];
  bool _loading = true;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  int get _lowStockCount => _items.where((i) => i.isLowStock).length;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items =
          await ref.read(inventoryRepositoryProvider).getItems(_farmId);
      if (!mounted) return;
      setState(() => _items = items);
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

  /// إنشاء أو تعديل عنصر
  Future<void> _showItemDialog({InventoryItemModel? item}) async {
    final nameCtrl = TextEditingController(text: item?.name ?? '');
    final qtyCtrl =
        TextEditingController(text: item?.quantity.toString() ?? '0');
    final thresholdCtrl =
        TextEditingController(text: item?.lowStockThreshold.toString() ?? '5');
    final notesCtrl = TextEditingController(text: item?.notes ?? '');
    var unit = item?.unit ?? InventoryUnit.piece;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(item == null ? 'عنصر جديد' : 'تعديل العنصر'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration:
                      const InputDecoration(labelText: 'اسم العنصر'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<InventoryUnit>(
                  initialValue: unit,
                  decoration: const InputDecoration(labelText: 'الوحدة'),
                  items: InventoryUnit.values
                      .map((u) => DropdownMenuItem(
                          value: u, child: Text(u.label)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDialog(() => unit = v);
                  },
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: qtyCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'الكمية الحالية'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: thresholdCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'حد التنبيه'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  decoration:
                      const InputDecoration(labelText: 'ملاحظات (اختياري)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty ||
                    double.tryParse(qtyCtrl.text.trim()) == null ||
                    double.tryParse(thresholdCtrl.text.trim()) == null) {
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
      await ref.read(inventoryRepositoryProvider).saveItem(InventoryItemModel(
            id: item?.id,
            farmId: _farmId,
            name: nameCtrl.text.trim(),
            unit: unit,
            quantity: double.parse(qtyCtrl.text.trim()),
            lowStockThreshold: double.parse(thresholdCtrl.text.trim()),
            notes:
                notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
          ));
      _load();
    } catch (e) {
      _error(e);
    }
  }

  /// حركة إدخال/إخراج
  Future<void> _adjust(InventoryItemModel item, {required bool isInput}) async {
    final qtyCtrl = TextEditingController();
    final noteCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isInput ? 'إدخال إلى المخزون' : 'إخراج من المخزون'),
        content: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${item.name} — المتوفر: ${item.quantity} ${item.unit.label}'),
            const SizedBox(height: 16),
            TextField(
              controller: qtyCtrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'الكمية'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration:
                  const InputDecoration(labelText: 'ملاحظة (اختياري)'),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              final q = double.tryParse(qtyCtrl.text.trim());
              if (q == null || q <= 0) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('تسجيل'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await ref.read(inventoryRepositoryProvider).adjustStock(
            itemId: item.id!,
            isInput: isInput,
            quantity: double.parse(qtyCtrl.text.trim()),
            note: noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
          );
      _load();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _delete(InventoryItemModel item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف العنصر'),
        content: Text('حذف "${item.name}" وكل حركاته؟'),
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
    if (ok != true || item.id == null) return;
    try {
      await ref.read(inventoryRepositoryProvider).deleteItem(item.id!);
      _load();
    } catch (e) {
      _error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Wrap(spacing: 8, children: [
                Chip(label: Text('عدد العناصر: ${_items.length}')),
                if (_lowStockCount > 0)
                  Chip(
                    label: Text('تنبيه: $_lowStockCount عنصر منخفض!'),
                    backgroundColor: Colors.red.shade100,
                  ),
              ]),
              FilledButton.icon(
                onPressed: () => _showItemDialog(),
                icon: const Icon(Icons.add),
                label: const Text('عنصر جديد'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Expanded(
                child: Center(child: CircularProgressIndicator()))
          else if (_items.isEmpty)
            const Expanded(child: Center(child: Text('المخزون فارغ')))
          else
            Expanded(
              child: SingleChildScrollView(
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('العنصر')),
                    DataColumn(label: Text('الكمية')),
                    DataColumn(label: Text('حد التنبيه')),
                    DataColumn(label: Text('الحالة')),
                    DataColumn(label: Text('آخر تحديث')),
                    DataColumn(label: Text('إجراءات')),
                  ],
                  rows: _items.map((i) {
                    return DataRow(cells: [
                      DataCell(Text(i.name)),
                      DataCell(Text(
                          '${NumberFormat('#,##0.##').format(i.quantity)} ${i.unit.label}')),
                      DataCell(Text(NumberFormat('#,##0.##').format(i.lowStockThreshold))),
                      DataCell(i.isLowStock
                          ? Tooltip(
                              message: 'الكمية منخفضة - أعد الطلب',
                              child: Chip(
                                label: const Text('منخفض'),
                                backgroundColor: Colors.red.shade100,
                              ),
                            )
                          : const Chip(label: Text('جيد'))),
                      DataCell(Text(i.updatedAt != null
                          ? DateFormat('yyyy/MM/dd').format(i.updatedAt!)
                          : '-')),
                      DataCell(Row(children: [
                        IconButton(
                          tooltip: 'إدخال',
                          icon: const Icon(Icons.add_circle_outline,
                              color: Colors.green),
                          onPressed: () => _adjust(i, isInput: true),
                        ),
                        IconButton(
                          tooltip: 'إخراج',
                          icon: const Icon(Icons.remove_circle_outline,
                              color: Colors.orange),
                          onPressed: () => _adjust(i, isInput: false),
                        ),
                        IconButton(
                          tooltip: 'تعديل',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _showItemDialog(item: i),
                        ),
                        IconButton(
                          tooltip: 'حذف',
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          onPressed: () => _delete(i),
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
