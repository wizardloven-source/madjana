import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/csv_exporter.dart';
import '../../../core/providers.dart';
import '../../../core/shell_state.dart';
import '../../../shared/widgets/period_filter.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة التخريج والقبض - للمدير فقط
///
/// يرى المدير فواتير التخريج (الكميات التي أدخلها العامل)
/// ويسجل سعر الكرتون والمبالغ المقبوضة.
class DispatchScreen extends ConsumerStatefulWidget {
  const DispatchScreen({super.key});

  @override
  ConsumerState<DispatchScreen> createState() => _DispatchScreenState();
}

class _DispatchScreenState extends ConsumerState<DispatchScreen> {
  List<DispatchModel> _dispatches = [];
  Map<String, CustomerModel> _customers = {};
  List<PaymentModel> _payments = [];
  bool _loading = true;
  int _currentStock = 0;
  DateTime _fromDate = DateTime(2020);
  DateTime _toDate = DateTime.now();
  String _search = '';
  String _farmName = '';

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';
  String get _managerId => ref.read(authProvider).currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final dispatchRepo = ref.read(dispatchRepositoryProvider);
    final paymentRepo = ref.read(paymentRepositoryProvider);
    final eggRepo = ref.read(eggProductionRepositoryProvider);
    final farmRepo = ref.read(farmRepositoryProvider);

    final dispatches = await dispatchRepo.getAll(farmId: _farmId);
    final customers = await dispatchRepo.getCustomers(_farmId);
    final payments = await paymentRepo.getAll(farmId: _farmId);
    String farmName = '';
    try {
      final farm = await farmRepo.getFarm(_farmId);
      farmName = farm.name;
    } catch (_) {}

    // المخزون الحي = كل الإنتاج - كل التخريج
    try {
      final produced =
          await eggRepo.getAllRecords(farmId: _farmId);
      var stock = produced.fold<int>(0, (s, e) => s + e.totalEggs) -
          dispatches.fold<int>(0, (s, d) => s + d.totalEggs);
      if (stock < 0) stock = 0;
      _currentStock = stock;
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _dispatches = dispatches;
      _customers = {for (final c in customers) c.id! : c};
      _payments = payments;
      _farmName = farmName;
      _loading = false;
    });
  }

  /// الفواتير بعد فلاتر الفترة والبحث
  List<DispatchModel> get _filtered {
    var list = _dispatches.where((d) {
      final inRange = !d.date.isBefore(DateTime(
              _fromDate.year, _fromDate.month, _fromDate.day)) &&
          !d.date.isAfter(DateTime(
              _toDate.year, _toDate.month, _toDate.day, 23, 59, 59));
      if (!inRange) return false;
      if (_search.isEmpty) return true;
      return _customerName(d.customerId).contains(_search);
    }).toList();

    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  /// فتح نافذة تسجيل القبض لفاتورة
  Future<void> _recordPayment(DispatchModel dispatch) async {
    final existing = _payments.where((p) => p.dispatchId == dispatch.id).toList();

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _PaymentDialog(
        dispatch: dispatch,
        customer: _customers[dispatch.customerId],
        existingPayments: existing,
      ),
    );

    if (result != null && mounted) {
      final payment = PaymentModel(
        farmId: _farmId,
        dispatchId: dispatch.id,
        customerId: dispatch.customerId,
        date: DateTime.now(),
        pricePerCarton: result['price'] as double,
        totalDue: result['totalDue'] as double,
        amountPaid: result['amountPaid'] as double,
        paymentMethod: result['method'] as PaymentMethod,
        notes: result['notes'] as String?,
        managerId: _managerId,
      );

      await ref.read(paymentRepositoryProvider).save(payment);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم تسجيل القبض بنجاح'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      _load();
    }
  }

  String _customerName(String? id) =>
      id == null ? '-' : (_customers[id]?.name ?? '-');

  Future<void> _showAddDispatchDialog() async {
    if (_customers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف زبائناً أولاً من شاشة الزبائن')),
      );
      return;
    }
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _DispatchEntryDialog(
        customers: _customers.values.toList(),
        currentStock: _currentStock,
        farmName: _farmName,
      ),
    );
    if (result != null && mounted) {
      final workerId = ref.read(authProvider).currentUser?.uid ?? 'manager';
      final record = DispatchModel(
        farmId: _farmId,
        date: result['date'] as DateTime,
        customerId: result['customer_id'] as String,
        cartons: result['cartons'] as int,
        trays: result['trays'] as int,
        trayWeightKg: result['tray_weight_kg'] as double?,
        notes: result['notes'] as String?,
        workerId: workerId,
      );
      await ref.read(dispatchRepositoryProvider).saveLocal(record);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ التخريج بنجاح')),
        );
        _load();
      }
    }
  }

  Future<void> _exportCsv() async {
    try {
      final path = await CsvExporter.saveCsv(
        fileName:
            'dispatches_${DateTime.now().toIso8601String().split('T').first}',
        rows: [
          ['التاريخ', 'الزبون', 'كراتين', 'أطباق', 'إجمالي البيض', 'وزن الصحن (كغ)', 'وزن البيضة (غم)', 'الحالة'],
          for (final d in _filtered)
            [
              Formatters.formatDate(d.date),
              _customerName(d.customerId),
              '${d.cartons}',
              '${d.trays}',
              '${d.totalEggs}',
              d.trayWeightKg?.toStringAsFixed(2) ?? '',
              d.avgEggWeightGrams?.toStringAsFixed(1) ?? '',
              _statusLabel(d.paymentStatus),
            ],
        ],
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم التصدير إلى: $path')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل التصدير: $e')),
      );
    }
  }

  String _statusLabel(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.unpaid:
        return 'غير مدفوع';
      case PaymentStatus.partial:
        return 'مدفوع جزئياً';
      case PaymentStatus.paid:
        return 'مدفوع';
    }
  }

  Color _statusColor(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.unpaid:
        return Colors.redAccent;
      case PaymentStatus.partial:
        return Colors.orangeAccent;
      case PaymentStatus.paid:
        return Colors.greenAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    // إعادة التحميل عند وصول بيانات من أجهزة أخرى
    ref.listen(dataRefreshTickProvider, (_, __) => _load());
    final filtered = _filtered;
    final totalEggs = filtered.fold<int>(0, (s, d) => s + d.totalEggs);
    final totalCartons = filtered.fold<int>(0, (s, d) => s + d.cartons);
    final unpaidCount = filtered
        .where((d) => d.paymentStatus != PaymentStatus.paid)
        .length;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // لوحة المخزون الحي + الإجماليات
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.12),
                  border: Border.all(color: Colors.teal),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.egg, color: Colors.teal),
                    const SizedBox(width: 8),
                    Text(
                      'مخزون البيض الحي: ${Formatters.formatNumber(_currentStock)} بيضة',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.teal,
                      ),
                    ),
                  ],
                ),
              ),
              Chip(
                label: Text('فواتير: ${filtered.length}'),
                avatar: const Icon(Icons.receipt_long, size: 18),
              ),
              Chip(
                label:
                    Text('كراتين: ${Formatters.formatNumber(totalCartons)}'),
                avatar: const Icon(Icons.inventory, size: 18),
              ),
              Chip(
                label: Text('إجمالي البيض: ${Formatters.formatNumber(totalEggs)}'),
                avatar: const Icon(Icons.egg_alt, size: 18),
              ),
              if (unpaidCount > 0)
                Chip(
                  label: Text('غير مدفوعة: $unpaidCount'),
                  avatar: const Icon(Icons.money_off, size: 18),
                  backgroundColor: Colors.redAccent.withValues(alpha: 0.12),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // فلاتر الفترة والبحث
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              QuickPeriodBar(
                fromDate: _fromDate,
                toDate: _toDate,
                onChanged: (period) =>
                    setState(() {
                      _fromDate = period.from;
                      _toDate = period.to;
                    }),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _fromDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) setState(() => _fromDate = d);
                },
                icon: const Icon(Icons.date_range),
                label: Text('من: ${Formatters.formatDate(_fromDate)}'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _toDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) setState(() => _toDate = d);
                },
                icon: const Icon(Icons.date_range),
                label: Text('إلى: ${Formatters.formatDate(_toDate)}'),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  onChanged: (v) => setState(() => _search = v.trim()),
                  decoration: InputDecoration(
                    hintText: 'بحث باسم الزبون...',
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: filtered.isEmpty ? null : _exportCsv,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('تصدير CSV'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _showAddDispatchDialog,
                icon: const Icon(Icons.add),
                label: const Text('إضافة تخريج'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'اضغط على أي فاتورة لتعيين سعر الكرتون وتسجيل المبلغ المقبوض',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? const Center(child: Text('لا توجد فواتير تخريج مطابقة'))
                    : SingleChildScrollView(
                        child: DataTable(
                          headingRowColor: WidgetStatePropertyAll(
                            Theme.of(context).colorScheme.surfaceContainerHighest,
                          ),
                          columns: const [
                            DataColumn(label: Text('التاريخ')),
                            DataColumn(label: Text('الزبون')),
                            DataColumn(label: Text('كراتين')),
                            DataColumn(label: Text('أطباق')),
                            DataColumn(label: Text('إجمالي البيض')),
                            DataColumn(label: Text('وزن الصحن')),
                            DataColumn(label: Text('الحالة')),
                          ],
                          rows: [
                            for (final d in filtered)
                              DataRow(
                                onSelectChanged: (_) => _recordPayment(d),
                                cells: [
                                  DataCell(Text(Formatters.formatDate(d.date))),
                                  DataCell(Text(_customerName(d.customerId))),
                                  DataCell(Text('${d.cartons}')),
                                  DataCell(Text('${d.trays}')),
                                  DataCell(
                                    Text(
                                      Formatters.formatNumber(d.totalEggs),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    d.trayWeightKg == null
                                        ? const Text('-')
                                        : Tooltip(
                                            message:
                                                '~${d.avgEggWeightGrams!.toStringAsFixed(1)} غم للبيضة',
                                            child: Text(
                                              '${d.trayWeightKg!.toStringAsFixed(2)} كغ',
                                            ),
                                          ),
                                  ),
                                  DataCell(
                                    Text(
                                      _statusLabel(d.paymentStatus),
                                      style: TextStyle(
                                        color: _statusColor(d.paymentStatus),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

/// نافذة تسجيل القبض
class _PaymentDialog extends StatefulWidget {
  final DispatchModel dispatch;
  final CustomerModel? customer;
  final List<PaymentModel> existingPayments;

  const _PaymentDialog({
    required this.dispatch,
    required this.customer,
    required this.existingPayments,
  });

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  final _priceController = TextEditingController();
  final _amountController = TextEditingController();
  final _notesController = TextEditingController();
  PaymentMethod _method = PaymentMethod.cash;

  @override
  void initState() {
    super.initState();
    // تعبئة السعر من قبض سابق إن وجد
    if (widget.existingPayments.isNotEmpty) {
      _priceController.text =
          widget.existingPayments.last.pricePerCarton.toStringAsFixed(0);
    }
  }

  @override
  void dispose() {
    _priceController.dispose();
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paidSoFar =
        widget.existingPayments.fold<double>(0, (s, p) => s + p.amountPaid);
    final totalDue = _priceController.text.isNotEmpty
        ? double.tryParse(_priceController.text) ?? 0.0
        : 0.0;
    final remaining = (totalDue * widget.dispatch.cartons) - paidSoFar;

    return AlertDialog(
      title: Text('قبض فاتورة - ${widget.customer?.name ?? ''}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('التاريخ: ${Formatters.formatDate(widget.dispatch.date)}'),
              Text('الكراتين: ${widget.dispatch.cartons}'),
              const SizedBox(height: 8),
              TextField(
                controller: _priceController,
                keyboardType: TextInputType.number,
                textDirection: TextDirection.ltr,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'سعر الكرتون (د.ع)',
                  prefixIcon: Icon(Icons.attach_money),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'إجمالي المستحق: ${Formatters.formatCurrency(totalDue * widget.dispatch.cartons)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                'المسدد سابقاً: ${Formatters.formatCurrency(paidSoFar)}',
                style: const TextStyle(color: Colors.orangeAccent),
              ),
              Text(
                'المتبقي: ${Formatters.formatCurrency(remaining < 0 ? 0 : remaining)}',
                style: const TextStyle(color: Colors.redAccent),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'المبلغ المقبوض (د.ع)',
                  prefixIcon: Icon(Icons.payments),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<PaymentMethod>(
                value: _method,
                decoration: const InputDecoration(
                  labelText: 'طريقة الدفع',
                  prefixIcon: Icon(Icons.account_balance_wallet),
                ),
                items: const [
                  DropdownMenuItem(
                    value: PaymentMethod.cash,
                    child: Text('نقدي'),
                  ),
                  DropdownMenuItem(
                    value: PaymentMethod.transfer,
                    child: Text('تحويل'),
                  ),
                  DropdownMenuItem(
                    value: PaymentMethod.check,
                    child: Text('شيك'),
                  ),
                  DropdownMenuItem(
                    value: PaymentMethod.credit,
                    child: Text('آجل'),
                  ),
                ],
                onChanged: (v) => setState(() => _method = v ?? PaymentMethod.cash),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'ملاحظات',
                  prefixIcon: Icon(Icons.notes),
                ),
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
        FilledButton(
          onPressed: () {
            final price = double.tryParse(_priceController.text);
            final amount = double.tryParse(_amountController.text);
            if (price == null || price <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('أدخل سعراً صحيحاً')),
              );
              return;
            }
            Navigator.pop(context, {
              'price': price,
              'totalDue': price * widget.dispatch.cartons,
              'amountPaid': amount ?? 0,
              'method': _method,
              'notes': _notesController.text.isEmpty
                  ? null
                  : _notesController.text,
            });
          },
          child: const Text('حفظ القبض'),
        ),
      ],
    );
  }
}

/// نافذة إدخال تخريج بيض
class _DispatchEntryDialog extends StatefulWidget {
  final List<CustomerModel> customers;
  final int currentStock;
  final String farmName;
  const _DispatchEntryDialog({required this.customers, required this.currentStock, required this.farmName});
  @override
  State<_DispatchEntryDialog> createState() => _DispatchEntryDialogState();
}

class _DispatchEntryDialogState extends State<_DispatchEntryDialog> {
  String? _customerId;
  DateTime _date = DateTime.now();
  final _cartonsCtrl = TextEditingController();
  final _traysCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  @override
  void dispose() {
    _cartonsCtrl.dispose();
    _traysCtrl.dispose();
    _weightCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  int get _totalEggs {
    final c = int.tryParse(_cartonsCtrl.text) ?? 0;
    final t = int.tryParse(_traysCtrl.text) ?? 0;
    return EggCalculator.calculateTotal(cartons: c, trays: t, looseEggs: 0);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة تخريج بيض'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'المدجنة: ${widget.farmName}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 12),
              if (widget.currentStock > 0)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'المخزون الحالي: ${Formatters.formatNumber(widget.currentStock)} بيضة',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal),
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _customerId,
                decoration: const InputDecoration(
                  labelText: 'الزبون',
                  border: OutlineInputBorder(),
                ),
                items: widget.customers
                    .map((c) => DropdownMenuItem(value: c.id, child: Text(c.name)))
                    .toList(),
                onChanged: (v) => setState(() => _customerId = v),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) setState(() => _date = d);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'التاريخ',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.calendar_today),
                  ),
                  child: Text(Formatters.formatDate(_date)),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _cartonsCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'كراتين',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _traysCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'أطباق',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _weightCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'وزن الصحن كغ (اختياري)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notesCtrl,
                decoration: const InputDecoration(
                  labelText: 'ملاحظات',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'إجمالي البيض: ${Formatters.formatNumber(_totalEggs)}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
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
        FilledButton(
          onPressed: () {
            if (_customerId == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('اختر الزبون')),
              );
              return;
            }
            final cartons = int.tryParse(_cartonsCtrl.text) ?? 0;
            final trays = int.tryParse(_traysCtrl.text) ?? 0;
            if (cartons == 0 && trays == 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('أدخل كمية التخريج')),
              );
              return;
            }
            if (_totalEggs > widget.currentStock) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('الكمية أكبر من المخزون المتاح')),
              );
              return;
            }
            Navigator.pop(context, {
              'customer_id': _customerId!,
              'date': _date,
              'cartons': cartons,
              'trays': trays,
              'tray_weight_kg': double.tryParse(_weightCtrl.text),
              'notes': _notesCtrl.text.isEmpty ? null : _notesCtrl.text,
            });
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}