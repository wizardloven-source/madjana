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

  // الرصيد التلقائي (يحسب من السجلات: علف وبيض)
  double _feedStockKg = 0;
  double _feedReceivedKg = 0;
  double _feedConsumedKg = 0;
  double _bagWeightKg = 50;
  int _eggsProduced = 0;
  int _eggsDispatched = 0;
  int _eggStock = 0;

  // مخزون صحون الكرتون (صحن): المشترى (ربطات × 100) - المستهلك (كراتين×12 + أطباق)
  int _cartonPurchasedTrays = 0;
  int _cartonConsumedTrays = 0;
  int _cartonStockTrays = 0;
  int _cartonLowThreshold = 100;

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
      final feedRepo = ref.read(feedRepositoryProvider);
      final eggRepo = ref.read(eggProductionRepositoryProvider);
      final dispatchRepo = ref.read(dispatchRepositoryProvider);
      final farmRepo = ref.read(farmRepositoryProvider);
      final expenseRepo = ref.read(expenseRepositoryProvider);

      // رصيد العلف: الوارد - المستهلك
      final received = await feedRepo.getAllReceived(farmId: _farmId);
      final consumed = await feedRepo.getAllConsumption(farmId: _farmId);
      final stockIl = await feedRepo.getCurrentFeedStock(_farmId);
      final receivedIl = received.fold<double>(0, (s, r) => s + r.quantityKg);
      final consumedIl =
          consumed.fold<double>(0, (s, r) => s + r.quantityKg);

      // رصيد البيض: الإنتاج (صالح للبيع) - التخريج
      final production = await eggRepo.getAllRecords(farmId: _farmId);
      final dispatches = await dispatchRepo.getAll(farmId: _farmId);
      final producedIl = production.fold<int>(
          0,
          (s, e) =>
              s + (e.totalEggs - e.brokenEggs - e.dirtyEggs));
      final dispatchedIl =
          dispatches.fold<int>(0, (s, d) => s + d.totalEggs);

      // صافي رصيد القطعان القديمة (opening balances) للإبقاء على اتساق لوحة التحكم
      final openingNet = (await ref
              .read(openingBalanceRepositoryProvider)
              .getForFarm(_farmId))
          .fold<int>(0, (s, b) => s + b.eggsProduced - b.eggsDispatched);

      // مخزون صحون الكرتون: المشترى (ربطات × 100 صحن) - المستهلك (كراتين×12 + أطباق)
      final cartonExpenses = await expenseRepo.getExpenses(farmId: _farmId);
      final purchasedTrays = cartonExpenses
          .where((e) =>
              e.category == ExpenseCategory.carton &&
              e.cartonBundles != null)
          .fold<int>(0, (s, e) => s + (e.cartonBundles ?? 0) * AppConstants.traysPerBundle);
      final consumedTrays = dispatches.fold<int>(
          0,
          (s, d) =>
              s + d.cartons * AppConstants.traysPerCarton + d.trays);

      double bagWeight = 50;
      int cartonThreshold = 100;
      try {
        final farm = await farmRepo.getFarm(_farmId);
        bagWeight = farm.feedBagWeightKg;
        cartonThreshold = farm.cartonLowThreshold;
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _items = items;
        _feedStockKg = stockIl;
        _feedReceivedKg = receivedIl;
        _feedConsumedKg = consumedIl;
        _bagWeightKg = bagWeight;
        _eggsProduced = producedIl;
        _eggsDispatched = dispatchedIl;
        _eggStock = producedIl - dispatchedIl + openingNet;
        _cartonPurchasedTrays = purchasedTrays;
        _cartonConsumedTrays = consumedTrays;
        _cartonStockTrays = purchasedTrays - consumedTrays;
        _cartonLowThreshold = cartonThreshold;
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
                  value: unit,
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
          _buildAutoStockSection(),
          const SizedBox(height: 16),
          if (_loading)
            const Expanded(
                child: Center(child: CircularProgressIndicator()))
          else if (_items.isEmpty)
            const Expanded(child: Center(child: Text('المخزون فارغ')))
          else
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.vertical,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
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
            ),
        ],
      ),
    );
  }

  /// قسم الرصيد التلقائي: رصيد العلف والبيض المحسوب من السجلات
  Widget _buildAutoStockSection() {
    final feedBags = _bagWeightKg > 0 ? _feedStockKg / _bagWeightKg : 0;
    final feedLow = _feedStockKg <= 0;

    // تحويل رصيد البيض إلى كراتين/أطباق/مفرد
    final cartons = _eggStock ~/ AppConstants.eggsPerCarton;
    final remAfterCartons = _eggStock % AppConstants.eggsPerCarton;
    final trays = remAfterCartons ~/ AppConstants.eggsPerTray;
    final loose = remAfterCartons % AppConstants.eggsPerTray;

    String eggStockLabel;
    if (_eggStock <= 0) {
      eggStockLabel = 'لا يوجد رصيد';
    } else if (cartons > 0 && trays > 0) {
      eggStockLabel = '$cartons كرتون + $trays صحن';
    } else if (cartons > 0) {
      eggStockLabel = '$cartons كرتون';
    } else if (trays > 0) {
      eggStockLabel = '$trays صحن';
    } else {
      eggStockLabel = '$loose بيضة';
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: feedLow ? Colors.red.shade200 : Colors.green.shade200,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.grain_rounded,
                          color: Colors.orange.shade700, size: 28),
                      const SizedBox(width: 8),
                      const Text('رصيد العلف',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'الرصيد الحالي: ${NumberFormat('#,##0.#').format(_feedStockKg)} كغ '
                    '(≈ ${NumberFormat('#,##0.#').format(feedBags)} كيس)',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: feedLow ? Colors.red : Colors.green.shade800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'الوارد: ${NumberFormat('#,##0.#').format(_feedReceivedKg)} كغ  ·  '
                    'المستهلك: ${NumberFormat('#,##0.#').format(_feedConsumedKg)} كغ',
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'وزن الكيس: ${NumberFormat('#,##0.#').format(_bagWeightKg)} كغ',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: _eggStock <= 0
                    ? Colors.red.shade200
                    : Colors.amber.shade200,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.egg_alt_rounded,
                          color: Colors.amber.shade800, size: 28),
                      const SizedBox(width: 8),
                      const Text('رصيد البيض',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    eggStockLabel,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: _eggStock <= 0
                          ? Colors.red
                          : Colors.amber.shade900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'الإنتاج: ${NumberFormat('#,##0').format(_eggsProduced)} بيضة  ·  '
                    'التخريج: ${NumberFormat('#,##0').format(_eggsDispatched)} بيضة',
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'الرصيد: ${NumberFormat('#,##0').format(_eggStock)} بيضة',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        _buildCartonStockCard(),
      ],
    );
  }

  /// بطاقة مخزون صحون الكرتون (مشترى بالربطات - مستهلك بالتخريج)
  Widget _buildCartonStockCard() {
    final cartonLow = _cartonStockTrays < _cartonLowThreshold;
    final bundles = _cartonStockTrays ~/ AppConstants.traysPerBundle;
    final remTrays = _cartonStockTrays % AppConstants.traysPerBundle;

    String label;
    if (_cartonStockTrays <= 0) {
      label = 'لا يوجد رصيد';
    } else if (bundles > 0 && remTrays > 0) {
      label = '$bundles ربطة + $remTrays صحن';
    } else if (bundles > 0) {
      label = '$bundles ربطة';
    } else {
      label = '$remTrays صحن';
    }

    return Expanded(
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: cartonLow ? Colors.red.shade200 : Colors.teal.shade200,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.inventory_2_outlined,
                      color: Colors.teal.shade700, size: 28),
                  const SizedBox(width: 8),
                  const Text('مخزون صحون الكرتون',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: cartonLow ? Colors.red : Colors.teal.shade800,
                ),
              ),
              if (cartonLow)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '⚠ تحذير: الرصيد أقل من حد التنبيه ($_cartonLowThreshold صحن)',
                    style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'المشترى: ${NumberFormat('#,##0').format(_cartonPurchasedTrays)} صحن  ·  '
                'المستهلك: ${NumberFormat('#,##0').format(_cartonConsumedTrays)} صحن',
                style: TextStyle(color: Colors.grey.shade700),
              ),
              const SizedBox(height: 4),
              Text(
                'الرصيد: ${NumberFormat('#,##0').format(_cartonStockTrays)} صحن  '
                '(حد التنبيه: $_cartonLowThreshold)',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 4),
              Text(
                'يُراجع من إعدادات المدجنة · كل ربطة = ${AppConstants.traysPerBundle} صحن',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
