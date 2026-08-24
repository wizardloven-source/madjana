import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/csv_exporter.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/period_filter.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة إنتاج البيض (عرض وتقرير للمدير)
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
                  initialValue: _flockFilter,
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
