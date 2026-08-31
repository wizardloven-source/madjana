import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/csv_exporter.dart';
import '../../../core/providers.dart';
import '../../../core/shell_state.dart';
import '../../../shared/widgets/period_filter.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة النفوق (عرض + إدخال للمدير)
class MortalityScreen extends ConsumerStatefulWidget {
  const MortalityScreen({super.key});

  @override
  ConsumerState<MortalityScreen> createState() => _MortalityScreenState();
}

class _MortalityScreenState extends ConsumerState<MortalityScreen> {
  List<MortalityModel> _records = [];
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
      _flocks = await ref.read(flockRepositoryProvider).getFlocks(_farmId, includeEnded: true);
    } catch (_) {
      _flocks = [];
    }
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

  String _breedName(String flockId) {
    for (final f in _flocks) {
      if (f.id == flockId) return f.breed;
    }
    return '-';
  }

  List<MortalityModel> get _filtered =>
      _flockFilter == null || _flockFilter!.isEmpty
          ? _records
          : _records.where((r) => r.flockId == _flockFilter).toList();

  Future<void> _showAddDialog() async {
    if (_flocks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف قطيعاً أولاً من شاشة القطعان')),
      );
      return;
    }
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _MortalityDialog(flocks: _flocks, farmId: _farmId),
    );
    if (result != null && mounted) {
      final workerId = ref.read(authProvider).currentUser?.uid ?? 'manager';
      final record = MortalityModel(
        farmId: _farmId,
        flockId: result['flock_id'] as String,
        date: result['date'] as DateTime,
        count: result['count'] as int,
        reason: result['reason'] as MortalityReason,
        reasonOther: result['reason_other'] as String?,
        notes: result['notes'] as String?,
        workerId: workerId,
        sectionNo: result['section_no'] as int?,
      );
      await ref.read(mortalityRepositoryProvider).saveLocal(record);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ سجل النفوق بنجاح')),
        );
        _load();
      }
    }
  }

  Future<void> _exportCsv() async {
    try {
      final filtered = _filtered;
      final path = await CsvExporter.saveCsv(
        fileName:
            'mortality_${DateTime.now().toIso8601String().split('T').first}',
        rows: [
          ['التاريخ', 'المدجنة', 'العدد', 'السبب', 'ملاحظات'],
          for (final r in filtered)
            [
              Formatters.formatDate(r.date),
              _breedName(r.flockId),
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
    final filtered = _filtered;
    final total = filtered.fold<int>(0, (s, r) => s + r.count);

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
              SizedBox(
                width: 200,
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
              const SizedBox(width: 8),
              Chip(
                label: Text('إجمالي النفوق: ${Formatters.formatNumber(total)}'),
                avatar: const Icon(Icons.heart_broken, size: 18),
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
                          headingRowColor: WidgetStatePropertyAll(
                            Theme.of(context).colorScheme.surfaceContainerHighest,
                          ),
                          columns: const [
                            DataColumn(label: Text('التاريخ')),
                            DataColumn(label: Text('المدجنة')),
                            DataColumn(label: Text('العدد')),
                            DataColumn(label: Text('السبب')),
                            DataColumn(label: Text('ملاحظات')),
                          ],
                          rows: [
                            for (final r in filtered)
                              DataRow(
                                cells: [
                                  DataCell(Text(Formatters.formatDate(r.date))),
                                  DataCell(Text(_breedName(r.flockId))),
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

/// نافذة إدخال سجل النفوق
class _MortalityDialog extends StatefulWidget {
  final List<FlockModel> flocks;
  final String farmId;
  const _MortalityDialog({required this.flocks, required this.farmId});
  @override
  State<_MortalityDialog> createState() => _MortalityDialogState();
}

class _MortalityDialogState extends State<_MortalityDialog> {
  String? _flockId;
  DateTime _date = DateTime.now();
  final _countCtrl = TextEditingController();
  MortalityReason _reason = MortalityReason.unknown;
  final _otherCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  int? _sectionNo;

  FlockModel? get _selectedFlock =>
      _flockId == null
          ? null
          : widget.flocks.firstWhere(
              (f) => f.id == _flockId,
              orElse: () => widget.flocks.first,
            );

  @override
  void dispose() {
    _countCtrl.dispose();
    _otherCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة سجل نفوق'),
      content: SizedBox(
        width: 420,
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
                onChanged: (v) => setState(() {
                  _flockId = v;
                  _sectionNo = null;
                }),
              ),
              const SizedBox(height: 12),
              if (_selectedFlock != null &&
                  _selectedFlock!.sectionsCount > 1)
                DropdownButtonFormField<int>(
                  value: _sectionNo,
                  decoration: const InputDecoration(
                    labelText: 'العنبر',
                    border: OutlineInputBorder(),
                  ),
                  items: List.generate(
                    _selectedFlock!.sectionsCount,
                    (i) => DropdownMenuItem(
                      value: i + 1,
                      child: Text('العنبر ${i + 1}'),
                    ),
                  ),
                  onChanged: (v) => setState(() => _sectionNo = v),
                ),
              if (_selectedFlock != null &&
                  _selectedFlock!.sectionsCount > 1)
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
              TextField(
                controller: _countCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'عدد النفوق',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<MortalityReason>(
                value: _reason,
                decoration: const InputDecoration(
                  labelText: 'السبب',
                  border: OutlineInputBorder(),
                ),
                items: MortalityReason.values
                    .map((r) => DropdownMenuItem(value: r, child: Text(r.label)))
                    .toList(),
                onChanged: (v) => setState(() => _reason = v ?? MortalityReason.unknown),
              ),
              if (_reason == MortalityReason.other) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _otherCtrl,
                  decoration: const InputDecoration(
                    labelText: 'حدد السبب',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _notesCtrl,
                decoration: const InputDecoration(
                  labelText: 'ملاحظات',
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
            if (_flockId == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('اختر المدجنة')),
              );
              return;
            }
            final count = int.tryParse(_countCtrl.text) ?? 0;
            if (count <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('أدخل عدد صحيح')),
              );
              return;
            }
            Navigator.pop(context, {
              'flock_id': _flockId!,
              'date': _date,
              'count': count,
              'reason': _reason,
              'reason_other': _reason == MortalityReason.other ? _otherCtrl.text : null,
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
