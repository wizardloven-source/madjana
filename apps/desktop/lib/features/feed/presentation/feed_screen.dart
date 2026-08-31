import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/csv_exporter.dart';
import '../../../core/providers.dart';
import '../../../core/shell_state.dart';
import '../../../shared/widgets/period_filter.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة العلف (استهلاك + استلام) - للمدير
class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  List<FeedConsumptionModel> _consumption = [];
  List<FeedReceivedModel> _received = [];
  List<FlockModel> _flocks = [];
  double _stock = 0;
  bool _loading = true;
  int _tab = 0;
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate = DateTime.now();
  String _farmName = '';

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final feedRepo = ref.read(feedRepositoryProvider);
    final flockRepo = ref.read(flockRepositoryProvider);
    final farmRepo = ref.read(farmRepositoryProvider);
    final consumption = await feedRepo.getAllConsumption(
      farmId: _farmId,
      fromDate: _fromDate,
      toDate: _toDate,
    );
    final received = await feedRepo.getAllReceived(
      farmId: _farmId,
      fromDate: _fromDate,
      toDate: _toDate,
    );
    final stock = await feedRepo.getCurrentFeedStock(_farmId);
    List<FlockModel> flocks = [];
    try {
      flocks = await flockRepo.getFlocks(_farmId, includeEnded: true);
    } catch (_) {}
    String farmName = '';
    try {
      final farm = await farmRepo.getFarm(_farmId);
      farmName = farm.name;
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _consumption = consumption;
      _received = received;
      _flocks = flocks;
      _stock = stock;
      _farmName = farmName;
      _loading = false;
    });
  }

  Future<void> _showAddConsumptionDialog() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _FeedConsumptionDialog(
        flocks: _flocks,
        farmName: _farmName,
      ),
    );
    if (result != null && mounted) {
      final workerId = ref.read(authProvider).currentUser?.uid ?? 'manager';
      final mode = result['mode'] as FeedEntryMode;
      FeedConsumptionModel record;
      final sectionNo = result['section_no'] as int?;
      if (mode == FeedEntryMode.bags) {
        final bags = result['bags'] as int;
        record = FeedConsumptionModel(
          farmId: _farmId,
          date: result['date'] as DateTime,
          entryMode: FeedEntryMode.bags,
          bagsCount: bags,
          quantityKg: bags * AppConstants.kgPerBag,
          workerId: workerId,
          sectionNo: sectionNo,
        );
      } else {
        record = FeedConsumptionModel(
          farmId: _farmId,
          date: result['date'] as DateTime,
          entryMode: FeedEntryMode.kg,
          quantityKg: result['quantity_kg'] as double,
          workerId: workerId,
          sectionNo: sectionNo,
        );
      }
      await ref.read(feedRepositoryProvider).saveConsumptionLocal(record);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ استهلاك العلف بنجاح')),
        );
        _load();
      }
    }
  }

  Future<void> _showAddReceivedDialog() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _FeedReceivedDialog(
        flocks: _flocks,
        farmName: _farmName,
      ),
    );
    if (result != null && mounted) {
      final farmId = _farmId;
      if (farmId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('خطأ: لا توجد مدجنة مرتبطة بالحساب')),
        );
        return;
      }
      final record = FeedReceivedModel(
        id: null,
        farmId: farmId,
        date: result['date'] as DateTime,
        entryMode: result['mode'] as FeedEntryMode,
        quantity: result['quantity'] as double,
        quantityKg: result['quantity_kg'] as double,
        feedType: result['feed_type'] as FeedType,
        supplier: result['supplier'] as String?,
        invoiceNumber: result['invoice_number'] as String?,
        notes: result['notes'] as String?,
        sectionNo: result['section_no'] as int?,
      );
      await ref.read(feedRepositoryProvider).saveReceivedLocal(record);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ استلام العلف بنجاح')),
        );
        _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // إعادة التحميل عند وصول بيانات من أجهزة أخرى
    ref.listen(dataRefreshTickProvider, (_, __) => _load());
    final totalConsumed =
        _consumption.fold<double>(0, (s, r) => s + r.quantityKg);
    final totalReceived =
        _received.fold<double>(0, (s, r) => s + r.quantityKg);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          QuickPeriodBar(
            fromDate: _fromDate,
            toDate: _toDate,
            onChanged: (period) {
              setState(() {
                _fromDate = period.from;
                _toDate = period.to;
              });
              _load();
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Chip(
                label: Text('المخزون الحالي: ${Formatters.formatNumber(_stock.toInt())} كغ'),
                avatar: const Icon(Icons.warehouse, size: 18),
              ),
              Chip(
                label: Text('المستهلك: ${Formatters.formatNumber(totalConsumed.toInt())} كغ'),
                avatar: const Icon(Icons.remove_circle_outline, size: 18),
              ),
              Chip(
                label: Text('المستلم: ${Formatters.formatNumber(totalReceived.toInt())} كغ'),
                avatar: const Icon(Icons.add_circle_outline, size: 18),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _fromDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) {
                    setState(() => _fromDate = d);
                    _load();
                  }
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
                  if (d != null) {
                    setState(() => _toDate = d);
                    _load();
                  }
                },
                icon: const Icon(Icons.date_range),
                label: Text('إلى: ${Formatters.formatDate(_toDate)}'),
              ),
              FilledButton.tonalIcon(
                onPressed: _exportCsv,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('تصدير CSV'),
              ),
              const SizedBox(width: 8),
              if (_tab == 0)
                FilledButton.icon(
                  onPressed: _showAddConsumptionDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('إضافة استهلاك'),
                )
              else
                FilledButton.icon(
                  onPressed: _showAddReceivedDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('إضافة استلام'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 0,
                label: Text('الاستهلاك'),
                icon: Icon(Icons.restaurant),
              ),
              ButtonSegment(
                value: 1,
                label: Text('الاستلام'),
                icon: Icon(Icons.local_shipping),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _tab == 0
                    ? _consumptionTable()
                    : _receivedTable(),
          ),
        ],
      ),
    );
  }

  Widget _consumptionTable() {
    if (_consumption.isEmpty) {
      return const Center(child: Text('لا توجد بيانات'));
    }
    return SingleChildScrollView(
      child: DataTable(
        headingRowColor: WidgetStatePropertyAll(
          Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        columns: const [
          DataColumn(label: Text('التاريخ')),
          DataColumn(label: Text('الكمية (كغ)')),
          DataColumn(label: Text('أكياس')),
        ],
        rows: [
          for (final r in _consumption)
            DataRow(
              cells: [
                DataCell(Text(Formatters.formatDate(r.date))),
                DataCell(
                  Text(
                    Formatters.formatNumber(r.quantityKg),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                DataCell(Text(r.bagsCount == 0 ? '-' : '${r.bagsCount}')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _receivedTable() {
    if (_received.isEmpty) {
      return const Center(child: Text('لا توجد بيانات'));
    }
    return SingleChildScrollView(
      child: DataTable(
        headingRowColor: WidgetStatePropertyAll(
          Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        columns: const [
          DataColumn(label: Text('التاريخ')),
          DataColumn(label: Text('الكمية (كغ)')),
          DataColumn(label: Text('النوع')),
          DataColumn(label: Text('المورد')),
          DataColumn(label: Text('رقم الفاتورة')),
          DataColumn(label: Text('السعر / كغ')),
        ],
        rows: [
          for (final r in _received)
            DataRow(
              onSelectChanged: (_) => _showPriceDialog(r),
              cells: [
                DataCell(Text(Formatters.formatDate(r.date))),
                DataCell(
                  Text(
                    Formatters.formatNumber(r.quantityKg),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                DataCell(Text(_feedTypeLabel(r.feedType))),
                DataCell(Text(r.supplier ?? '-')),
                DataCell(Text(r.invoiceNumber ?? '-')),
                DataCell(_priceCell(r)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _priceCell(FeedReceivedModel r) {
    if (r.pricePerKg == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.orange.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'بانتظار التسعير',
          style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
        ),
      );
    }
    return Tooltip(
      message:
          'الإجمالي: ${Formatters.formatCurrency(r.totalPrice!)}',
      child: Text('${r.pricePerKg!.toStringAsFixed(2)} / كغ'),
    );
  }

  /// تسجيل سعر العلف المستلم — ينشئ فاتورة مصروف تلقائياً
  Future<void> _showPriceDialog(FeedReceivedModel r) async {
    final priceController =
        TextEditingController(text: r.pricePerKg?.toStringAsFixed(2) ?? '');
    double? total;
    final farmId = ref.read(authProvider).currentUser?.farmId;

    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('تسجيل سعر العلف'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('الكمية: ${Formatters.formatNumber(r.quantityKg)} كغ'),
                if (r.supplier != null && r.supplier!.isNotEmpty)
                  Text('المورد: ${r.supplier}'),
                if (r.invoiceNumber != null && r.invoiceNumber!.isNotEmpty)
                  Text('فاتورة رقم: ${r.invoiceNumber}'),
                const SizedBox(height: 16),
                TextField(
                  controller: priceController,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'سعر الكيلوغرام',
                    suffixText: 'ر.ي / كغ',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setDialogState(() {
                    total = double.tryParse(v);
                  }),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Text('إجمالي الفاتورة:'),
                      const Spacer(),
                      Text(
                        total == null || total! <= 0
                            ? '-'
                            : Formatters.formatCurrency(
                                total! * r.quantityKg,
                              ),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'سيتم إنشاء فاتورة في المصروفات تلقائياً',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                final price = double.tryParse(priceController.text);
                if (price == null || price <= 0) return;
                try {
                  await ref.read(feedRepositoryProvider).setReceivedPrice(
                        id: r.id!,
                        pricePerKg: price,
                      );

                  // فاتورة المصروف — مع تحديث الفاتورة السابقة إن وُجدت
                  final amount = price * r.quantityKg;
                  final marker = '[FR:${r.id}]';
                  final expenses = await ref
                      .read(expenseRepositoryProvider)
                      .getExpenses(farmId: farmId!);
                  ExpenseModel? existing;
                  for (final e in expenses) {
                    if ((e.description ?? '').contains(marker)) {
                      existing = e;
                      break;
                    }
                  }

                  final description =
                      'فاتورة علف ${r.supplier ?? ''} ${r.invoiceNumber ?? ''} $marker'
                          .trim();
                  if (existing != null) {
                    await ref.read(expenseRepositoryProvider).save(
                          existing.copyWith(
                            date: r.date,
                            amount: amount,
                            description: description,
                          ),
                        );
                  } else {
                    await ref.read(expenseRepositoryProvider).save(
                          ExpenseModel(
                            farmId: farmId!,
                            date: r.date,
                            category: ExpenseCategory.feed,
                            description: description,
                            amount: amount,
                            syncStatus: SyncStatus.synced,
                            createdAt: DateTime.now(),
                          ),
                        );
                  }

                  if (!mounted) return;
                  Navigator.pop(dialogContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'تم التسعير وإنشاء فاتورة بمبلغ ${Formatters.formatCurrency(amount)}',
                      ),
                    ),
                  );
                  _load();
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('فشل التسعير: $e')),
                  );
                }
              },
              child: const Text('حفظ التسعير'),
            ),
          ],
        ),
      ),
    );
  }

  String _feedTypeLabel(FeedType type) {
    switch (type) {
      case FeedType.starter:
        return 'بادئ';
      case FeedType.grower:
        return 'نامي';
      case FeedType.layer:
        return 'بياض';
      case FeedType.main:
        return 'علف رئيسي';
    }
  }

  Future<void> _exportCsv() async {
    try {
      final String fileName;
      final List<List<String>> rows;

      if (_tab == 0) {
        fileName =
            'feed_consumption_${DateTime.now().toIso8601String().split('T').first}';
        rows = [
          ['التاريخ', 'الكمية (كغ)', 'أكياس'],
          for (final r in _consumption)
            [
              Formatters.formatDate(r.date),
              '${r.quantityKg}',
              r.bagsCount == 0 ? '' : '${r.bagsCount}',
            ],
        ];
      } else {
        fileName =
            'feed_received_${DateTime.now().toIso8601String().split('T').first}';
        rows = [
          ['التاريخ', 'الكمية (كغ)', 'النوع', 'المورد', 'رقم الفاتورة', 'سعر الكغ', 'الإجمالي'],
          for (final r in _received)
            [
              Formatters.formatDate(r.date),
              '${r.quantityKg}',
              _feedTypeLabel(r.feedType),
              r.supplier ?? '',
              r.invoiceNumber ?? '',
              r.pricePerKg?.toStringAsFixed(2) ?? '',
              r.totalPrice?.toStringAsFixed(2) ?? '',
            ],
        ];
      }

      final path = await CsvExporter.saveCsv(fileName: fileName, rows: rows);
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
}

/// نافذة إدخال استهلاك علف
class _FeedConsumptionDialog extends StatefulWidget {
  final List<FlockModel> flocks;
  final String farmName;
  const _FeedConsumptionDialog({required this.flocks, required this.farmName});
  @override
  State<_FeedConsumptionDialog> createState() => _FeedConsumptionDialogState();
}

class _FeedConsumptionDialogState extends State<_FeedConsumptionDialog> {
  FeedEntryMode _mode = FeedEntryMode.bags;
  DateTime _date = DateTime.now();
  final _bagsCtrl = TextEditingController();
  final _kgCtrl = TextEditingController();
  int? _sectionNo;

  bool get _hasMultipleSections =>
      widget.flocks.any((f) => f.sectionsCount > 1);

  int get _maxSections => widget.flocks
      .where((f) => f.sectionsCount > 1)
      .fold<int>(1, (m, f) => f.sectionsCount > m ? f.sectionsCount : m);

  @override
  void dispose() {
    _bagsCtrl.dispose();
    _kgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة استهلاك علف'),
      content: SizedBox(
        width: 380,
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
              SegmentedButton<FeedEntryMode>(
                segments: const [
                  ButtonSegment(value: FeedEntryMode.bags, label: Text('أكياس')),
                  ButtonSegment(value: FeedEntryMode.kg, label: Text('كيلوغرام')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 12),
              if (_mode == FeedEntryMode.bags)
                TextField(
                  controller: _bagsCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'عدد الأكياس',
                    border: OutlineInputBorder(),
                    hintText: 'كل كيس 50 كجم',
                  ),
                )
              else
                TextField(
                  controller: _kgCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'الكمية بالكيلوغرام',
                    border: OutlineInputBorder(),
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
            if (_mode == FeedEntryMode.bags) {
              final bags = int.tryParse(_bagsCtrl.text) ?? 0;
              if (bags <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('أدخل عدد الأكياس')),
                );
                return;
              }
              Navigator.pop(context, {
                'mode': FeedEntryMode.bags,
                'date': _date,
                'bags': bags,
                'section_no': _sectionNo,
              });
            } else {
              final kg = double.tryParse(_kgCtrl.text) ?? 0;
              if (kg <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('أدخل الكمية')),
                );
                return;
              }
              Navigator.pop(context, {
                'mode': FeedEntryMode.kg,
                'date': _date,
                'quantity_kg': kg,
                'section_no': _sectionNo,
              });
            }
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}
/// نافذة إدخال استلام علف
class _FeedReceivedDialog extends StatefulWidget {
  final List<FlockModel> flocks;
  final String farmName;
  const _FeedReceivedDialog({required this.flocks, required this.farmName});
  @override
  State<_FeedReceivedDialog> createState() => _FeedReceivedDialogState();
}

class _FeedReceivedDialogState extends State<_FeedReceivedDialog> {
  FeedEntryMode _mode = FeedEntryMode.bags;
  DateTime _date = DateTime.now();
  final _quantityCtrl = TextEditingController();
  FeedType? _feedType;
  final _supplierCtrl = TextEditingController();
  final _invoiceCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  int? _sectionNo;

  bool get _hasMultipleSections =>
      widget.flocks.any((f) => f.sectionsCount > 1);

  int get _maxSections => widget.flocks
      .where((f) => f.sectionsCount > 1)
      .fold<int>(1, (m, f) => f.sectionsCount > m ? f.sectionsCount : m);

  double get _quantityKg {
    final qty = double.tryParse(_quantityCtrl.text) ?? 0;
    return switch (_mode) {
      FeedEntryMode.bags => qty * AppConstants.kgPerBag,
      FeedEntryMode.kg => qty,
      FeedEntryMode.ton => qty * AppConstants.kgPerTon,
    };
  }

  @override
  void dispose() {
    _quantityCtrl.dispose();
    _supplierCtrl.dispose();
    _invoiceCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة استلام علف'),
      content: SizedBox(
        width: 420,
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
              // التاريخ
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
              // نوع الوحدة
              SegmentedButton<FeedEntryMode>(
                segments: const [
                  ButtonSegment(value: FeedEntryMode.bags, label: Text('أكياس')),
                  ButtonSegment(value: FeedEntryMode.kg, label: Text('كيلوغرام')),
                  ButtonSegment(value: FeedEntryMode.ton, label: Text('طن')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 12),
              // الكمية
              TextField(
                controller: _quantityCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'الكمية (${switch (_mode) {
                    FeedEntryMode.bags => 'أكياس',
                    FeedEntryMode.kg => 'كغ',
                    FeedEntryMode.ton => 'طن',
                  }})',
                  border: const OutlineInputBorder(),
                  suffixText: _mode == FeedEntryMode.bags
                      ? '(${_quantityKg.toStringAsFixed(0)} كغ)'
                      : _mode == FeedEntryMode.ton
                          ? '(${_quantityKg.toStringAsFixed(0)} كغ)'
                          : null,
                ),
              ),
              const SizedBox(height: 12),
              // نوع العلف
              DropdownButtonFormField<FeedType>(
                value: _feedType,
                decoration: const InputDecoration(
                  labelText: 'نوع العلف',
                  border: OutlineInputBorder(),
                ),
                items: FeedType.values.map((type) {
                  final label = switch (type) {
                    FeedType.starter => 'بادئ',
                    FeedType.grower => 'نامي',
                    FeedType.layer => 'بيّاض',
                    FeedType.main => 'علف رئيسي',
                  };
                  return DropdownMenuItem(value: type, child: Text(label));
                }).toList(),
                onChanged: (v) => setState(() => _feedType = v),
              ),
              const SizedBox(height: 12),
              // المورد
              TextField(
                controller: _supplierCtrl,
                decoration: const InputDecoration(
                  labelText: 'اسم المورد (اختياري)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              // رقم الفاتورة
              TextField(
                controller: _invoiceCtrl,
                decoration: const InputDecoration(
                  labelText: 'رقم الفاتورة (اختياري)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              // ملاحظات
              TextField(
                controller: _notesCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'ملاحظات (اختياري)',
                  border: OutlineInputBorder(),
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
            final quantity = double.tryParse(_quantityCtrl.text) ?? 0;
            if (quantity <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('أدخل الكمية')),
              );
              return;
            }
            if (_feedType == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('اختر نوع العلف')),
              );
              return;
            }
            Navigator.pop(context, {
              'mode': _mode,
              'date': _date,
              'quantity': quantity,
              'quantity_kg': _quantityKg,
              'feed_type': _feedType!,
              'supplier': _supplierCtrl.text.isEmpty ? null : _supplierCtrl.text,
              'invoice_number': _invoiceCtrl.text.isEmpty ? null : _invoiceCtrl.text,
              'notes': _notesCtrl.text.isEmpty ? null : _notesCtrl.text,
              'section_no': _sectionNo,
            });
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}
