import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/csv_exporter.dart';
import '../../../core/providers.dart';
import '../../../core/shell_state.dart';
import '../../../shared/widgets/period_filter.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة إنتاج البيض (عرض + إدخال للمدير)
///
/// - فترة سريعة + فترة مخصصة
/// - فلترة حسب المدجنة
/// - أعمدة المدجنة والعنبر
/// - تصدير CSV
class EggProductionScreen extends ConsumerStatefulWidget {
  const EggProductionScreen({super.key});

  @override
  ConsumerState<EggProductionScreen> createState() => _EggProductionScreenState();
}

class _EggProductionScreenState extends ConsumerState<EggProductionScreen> {
  List<EggProductionModel> _records = [];
  List<FlockModel> _flocks = [];
  bool _loading = true;
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate = DateTime.now();
  String? _flockFilter;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    try {
      _flocks = await ref
          .read(flockRepositoryProvider)
          .getFlocks(_farmId, includeEnded: true);
    } catch (_) {
      _flocks = [];
    }

    final records = await ref.read(eggProductionRepositoryProvider).getAllRecords(
          farmId: _farmId,
          fromDate: _fromDate,
          toDate: _toDate,
        );
    if (!mounted) return;
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  String _breedName(String flockId) {
    for (final f in _flocks) {
      if (f.id == flockId) return f.breed;
    }
    return '-';
  }

  /// السجلات بعد فلتر المدجنة
  List<EggProductionModel> get _filtered =>
      _flockFilter == null || _flockFilter!.isEmpty
          ? _records
          : _records.where((r) => r.flockId == _flockFilter).toList();

  Future<void> _pickFromDate() async {
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
  }

  Future<void> _pickToDate() async {
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
  }

  Future<void> _showAddDialog() async {
    if (_flocks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف قطيعاً أولاً من شاشة القطعان')),
      );
      return;
    }
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _EggProductionDialog(flocks: _flocks, farmId: _farmId),
    );
    if (result != null && mounted) {
      final workerId = ref.read(authProvider).currentUser?.uid ?? 'manager';
      final record = EggProductionModel(
        farmId: _farmId,
        flockId: result['flock_id'] as String,
        date: result['date'] as DateTime,
        cartons: result['cartons'] as int,
        trays: result['trays'] as int,
        looseEggs: result['loose'] as int,
        brokenEggs: result['broken'] as int,
        dirtyEggs: result['dirty'] as int,
        sectionNo: result['section'] as int?,
        workerId: workerId,
      );
      await ref.read(eggProductionRepositoryProvider).saveLocal(record);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ سجل الإنتاج بنجاح')),
        );
        _load();
      }
    }
  }

  Future<void> _exportCsv() async {
    try {
      final path = await CsvExporter.saveCsv(
        fileName:
            'egg_production_${DateTime.now().toIso8601String().split('T').first}',
        rows: [
          ['التاريخ', 'المدجنة', 'العنبر', 'كراتين', 'أطباق', 'مفرد', 'الإجمالي', 'مكسور', 'أرضي'],
          for (final r in _filtered)
            [
              Formatters.formatDate(r.date),
              _breedName(r.flockId),
              r.sectionNo?.toString() ?? '-',
              '${r.cartons}',
              '${r.trays}',
              '${r.looseEggs}',
              '${r.totalEggs}',
              '${r.brokenEggs}',
              '${r.dirtyEggs}',
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

  @override
  Widget build(BuildContext context) {
    // إعادة التحميل عند وصول بيانات من أجهزة أخرى
    ref.listen(dataRefreshTickProvider, (_, __) => _load());
    final filtered = _filtered;
    final totalEggs = filtered.fold<int>(0, (s, r) => s + r.totalEggs);
    final totalCartons = filtered.fold<int>(0, (s, r) => s + r.cartons);
    final totalBroken = filtered.fold<int>(0, (s, r) => s + r.brokenEggs);

    // معدل الإنتاج % للفترة المعروضة
    final days = _toDate.difference(_fromDate).inDays + 1;
    final birds = _flocks
        .where((f) => f.status == FlockStatus.active)
        .fold<int>(0, (s, f) => s + f.currentCount);
    final prodRate = FarmAnalytics.avgProductionRate(
      totalEggs: totalEggs,
      birdCount: birds,
      days: days,
    );

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
              OutlinedButton.icon(
                onPressed: _pickFromDate,
                icon: const Icon(Icons.date_range),
                label: Text('من: ${Formatters.formatDate(_fromDate)}'),
              ),
              OutlinedButton.icon(
                onPressed: _pickToDate,
                icon: const Icon(Icons.date_range),
                label: Text('إلى: ${Formatters.formatDate(_toDate)}'),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  value: _flockFilter,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'المدجنة',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('الكل')),
                    ..._flocks.map((f) =>
                        DropdownMenuItem(value: f.id, child: Text(f.breed))),
                  ],
                  onChanged: (v) => setState(() => _flockFilter = v),
                ),
              ),
              const Spacer(),
              Chip(
                label: Text('الإجمالي: ${Formatters.formatNumber(totalEggs)} بيضة'),
                avatar: const Icon(Icons.egg_alt, size: 18),
              ),
              Chip(
                label: Text('كراتين: ${Formatters.formatNumber(totalCartons)}'),
                avatar: const Icon(Icons.inventory, size: 18),
              ),
              Chip(
                label: Text('مكسور: ${Formatters.formatNumber(totalBroken)}'),
                avatar: const Icon(Icons.warning_amber, size: 18),
              ),
              if (birds > 0)
                Chip(
                  label: Text(
                    'معدل الإنتاج: ${prodRate.toStringAsFixed(1)}%',
                    style: TextStyle(
                      color: prodRate >= 80
                          ? Colors.green
                          : (prodRate >= 60 ? Colors.orange : Colors.redAccent),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  avatar: Icon(
                    Icons.percent,
                    size: 18,
                    color: prodRate >= 80
                        ? Colors.green
                        : (prodRate >= 60 ? Colors.orange : Colors.redAccent),
                  ),
                ),
              FilledButton.tonalIcon(
                onPressed: filtered.isEmpty ? null : _exportCsv,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('تصدير CSV'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _showAddDialog,
                icon: const Icon(Icons.add),
                label: const Text('إضافة سجل'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? const Center(child: Text('لا توجد بيانات'))
                    : SingleChildScrollView(
                        child: DataTable(
                          sortAscending: true,
                          headingRowColor: WidgetStatePropertyAll(
                            Theme.of(context).colorScheme.surfaceContainerHighest,
                          ),
                          columns: const [
                            DataColumn(label: Text('التاريخ')),
                            DataColumn(label: Text('المدجنة')),
                            DataColumn(label: Text('العنبر')),
                            DataColumn(label: Text('كراتين')),
                            DataColumn(label: Text('أطباق')),
                            DataColumn(label: Text('مفرد')),
                            DataColumn(label: Text('الإجمالي')),
                            DataColumn(label: Text('مكسور')),
                            DataColumn(label: Text('أرضي')),
                          ],
                          rows: [
                            for (final r in filtered)
                              DataRow(
                                cells: [
                                  DataCell(Text(Formatters.formatDate(r.date))),
                                  DataCell(Text(_breedName(r.flockId))),
                                  DataCell(Text(r.sectionNo?.toString() ?? '-')),
                                  DataCell(Text('${r.cartons}')),
                                  DataCell(Text('${r.trays}')),
                                  DataCell(Text('${r.looseEggs}')),
                                  DataCell(
                                    Text(
                                      Formatters.formatNumber(r.totalEggs),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  DataCell(Text('${r.brokenEggs}')),
                                  DataCell(Text('${r.dirtyEggs}')),
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

/// نافذة إدخال سجل إنتاج بيض
class _EggProductionDialog extends StatefulWidget {
  final List<FlockModel> flocks;
  final String farmId;
  const _EggProductionDialog({required this.flocks, required this.farmId});
  @override
  State<_EggProductionDialog> createState() => _EggProductionDialogState();
}

class _EggProductionDialogState extends State<_EggProductionDialog> {
  String? _flockId;
  DateTime _date = DateTime.now();
  final _cartonsCtrl = TextEditingController();
  final _traysCtrl = TextEditingController();
  final _looseCtrl = TextEditingController(text: '0');
  final _brokenCtrl = TextEditingController(text: '0');
  final _dirtyCtrl = TextEditingController(text: '0');
  int? _sectionNo;

  @override
  void dispose() {
    _cartonsCtrl.dispose();
    _traysCtrl.dispose();
    _looseCtrl.dispose();
    _brokenCtrl.dispose();
    _dirtyCtrl.dispose();
    super.dispose();
  }

  int get _total {
    final c = int.tryParse(_cartonsCtrl.text) ?? 0;
    final t = int.tryParse(_traysCtrl.text) ?? 0;
    final l = int.tryParse(_looseCtrl.text) ?? 0;
    return EggCalculator.calculateTotal(cartons: c, trays: t, looseEggs: l);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة إنتاج بيض'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                value: _flockId,
                decoration: const InputDecoration(
                  labelText: 'المدجنة',
                  border: OutlineInputBorder(),
                ),
                items: widget.flocks
                    .where((f) => f.status == FlockStatus.active)
                    .map((f) => DropdownMenuItem(value: f.id, child: Text(f.breed)))
                    .toList(),
                onChanged: (v) => setState(() => _flockId = v),
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
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _looseCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'مفرد',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _brokenCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'مكسور',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _dirtyCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'أرضي',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'رقم العنبر (اختياري)',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => _sectionNo = int.tryParse(v),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'الإجمالي: $_total بيضة',
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
            if (_flockId == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('اختر المدجنة')),
              );
              return;
            }
            if (_total == 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('أدخل كمية البيض')),
              );
              return;
            }
            Navigator.pop(context, {
              'flock_id': _flockId!,
              'date': _date,
              'cartons': int.tryParse(_cartonsCtrl.text) ?? 0,
              'trays': int.tryParse(_traysCtrl.text) ?? 0,
              'loose': int.tryParse(_looseCtrl.text) ?? 0,
              'broken': int.tryParse(_brokenCtrl.text) ?? 0,
              'dirty': int.tryParse(_dirtyCtrl.text) ?? 0,
              'section': _sectionNo,
            });
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}
