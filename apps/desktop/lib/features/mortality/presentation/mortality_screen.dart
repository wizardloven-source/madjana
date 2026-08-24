import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/csv_exporter.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/period_filter.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة النفوق (عرض وتقرير للمدير)
class MortalityScreen extends ConsumerStatefulWidget {
  const MortalityScreen({super.key});

  @override
  ConsumerState<MortalityScreen> createState() => _MortalityScreenState();
}

class _MortalityScreenState extends ConsumerState<MortalityScreen> {
  List<MortalityModel> _records = [];
  bool _loading = true;
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate = DateTime.now();

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final records = await ref.read(mortalityRepositoryProvider).getAllRecords(
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

  String _reasonLabel(MortalityModel m) =>
      m.reason == MortalityReason.other
          ? (m.reasonOther ?? 'أخرى')
          : m.reason.label;

  Future<void> _exportCsv() async {
    try {
      final path = await CsvExporter.saveCsv(
        fileName:
            'mortality_${DateTime.now().toIso8601String().split('T').first}',
        rows: [
          ['التاريخ', 'العدد', 'السبب', 'ملاحظات'],
          for (final r in _records)
            [
              Formatters.formatDate(r.date),
              '${r.count}',
              _reasonLabel(r),
              r.notes ?? '',
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
    final total = _records.fold<int>(0, (s, r) => s + r.count);

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
              const SizedBox(width: 8),
              Chip(
                label: Text('إجمالي النفوق: ${Formatters.formatNumber(total)}'),
                avatar: const Icon(Icons.heart_broken, size: 18),
              ),
              FilledButton.tonalIcon(
                onPressed: _records.isEmpty ? null : _exportCsv,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('تصدير CSV'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _records.isEmpty
                    ? const Center(child: Text('لا توجد بيانات'))
                    : SingleChildScrollView(
                        child: DataTable(
                          headingRowColor: WidgetStatePropertyAll(
                            Theme.of(context).colorScheme.surfaceContainerHighest,
                          ),
                          columns: const [
                            DataColumn(label: Text('التاريخ')),
                            DataColumn(label: Text('العدد')),
                            DataColumn(label: Text('السبب')),
                            DataColumn(label: Text('ملاحظات')),
                          ],
                          rows: [
                            for (final r in _records)
                              DataRow(
                                cells: [
                                  DataCell(Text(Formatters.formatDate(r.date))),
                                  DataCell(
                                    Text(
                                      '${r.count}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  DataCell(Text(_reasonLabel(r))),
                                  DataCell(Text(r.notes ?? '-')),
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
