import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/farm_dropdown.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة التوزيع (W7.2) — معاينة حصص الشركاء من صافي ربح المدجنة لفترة.
///
/// تعتمد على دالة M24 `calculate_profit_distribution` وهي **read-only**:
/// تُعاين فقط ولا تكتب صفوف توزيع. لا يوجد مسار مدعوم في القاعدة لترحيل
/// المعاينة إلى صفوف مخزّنة (فصل `profit_share` عن `salary_total` غير مُتاح)،
/// لذلك لا نخترع واحداً هنا. المبالغ بالدولار دائماً (M29v2).
class ProfitDistributionScreen extends ConsumerStatefulWidget {
  const ProfitDistributionScreen({super.key});

  @override
  ConsumerState<ProfitDistributionScreen> createState() =>
      _ProfitDistributionScreenState();
}

class _ProfitDistributionScreenState
    extends ConsumerState<ProfitDistributionScreen> {
  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _toDate = DateTime.now();
  String? _flockId;

  List<FlockModel> _flocks = const [];
  Map<String, String> _partnerNames = const {};
  List<ProfitDistributionPreview> _rows = const [];

  bool _loading = false;
  String? _error;
  bool _ranOnce = false;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _loadContext();
  }

  Future<void> _loadContext() async {
    try {
      final flocks =
          await ref.read(flockRepositoryProvider).getFlocks(_farmId);
      final partners = await ref.read(partnerRepositoryProvider).getPartners();
      if (!mounted) return;
      setState(() {
        _flocks = flocks;
        _partnerNames = {for (final p in partners) p.id!: p.name};
      });
    } catch (e) {
      // سياق القوائم ثانوي؛ أخطاء الضغط الحقيقي تظهر عند تشغيل المعاينة.
      debugPrint('madjana: partnership context load failed: $e');
    }
  }

  Future<void> _run() async {
    if (_farmId.isEmpty) {
      setState(() => _error = 'لا مدجنة فعّالة');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _ranOnce = true;
    });
    try {
      final rows = await ref.read(partnershipRepositoryProvider)
          .calculateDistribution(
        farmId: _farmId,
        periodStart: _fromDate,
        periodEnd: _toDate,
        flockId: _flockId,
      );
      if (!mounted) return;
      setState(() => _rows = rows);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
    }
  }

  double get _total =>
      _rows.fold(0, (sum, r) => sum + r.amount);

  String _name(String partnerId) =>
      _partnerNames[partnerId] ?? partnerId.substring(0, 8);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final farms =
        ref.watch(currentUserFarmsProvider).valueOrNull ?? const <FarmModel>[];
    var farmName = 'المدجنة';
    for (final f in farms) {
      if (f.id == _farmId) {
        farmName = f.name;
        break;
      }
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Chip(
                avatar: const Icon(Icons.pie_chart_rounded, size: 18),
                label: Text(farmName),
              ),
              _dateChip(
                label: 'من',
                value: _fromDate,
                onTap: () => _pickDate(isFrom: true),
              ),
              _dateChip(
                label: 'إلى',
                value: _toDate,
                onTap: () => _pickDate(isFrom: false),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: DropdownButtonFormField<String?>(
                  initialValue: _flockId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'القطيع',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('كل المدجنة'),
                    ),
                    for (final f in _flocks)
                      DropdownMenuItem<String?>(
                        value: f.id,
                        child: Text(
                          '${f.breed} • ${_formatDate(f.startDate)}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _flockId = v),
                ),
              ),
              FilledButton.icon(
                onPressed: _loading ? null : _run,
                icon: const Icon(Icons.calculate_rounded, size: 18),
                label: const Text('معاينة التوزيع'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.gpp_bad_rounded,
                        size: 48, color: theme.colorScheme.error),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _run,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              ),
            )
          else if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (!_ranOnce)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.pie_chart_outline_rounded,
                        size: 48, color: theme.colorScheme.outline),
                    const SizedBox(height: 12),
                    const Text('اختر الفترة ثم اضغط «معاينة التوزيع»'),
                  ],
                ),
              ),
            )
          else if (_rows.isEmpty)
            const Expanded(child: Center(child: Text('لا يوجد شركاء نشطون')))
          else
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('الشريك')),
                          DataColumn(label: Text('نموذج الحصة')),
                          DataColumn(label: Text('القيمة')),
                          DataColumn(label: Text('المبلغ (دولار)')),
                        ],
                        rows: _rows
                            .map((r) => DataRow(cells: [
                                  DataCell(Text(_name(r.partnerId))),
                                  DataCell(Text(r.shareType.label)),
                                  DataCell(Text(_valueLabel(r))),
                                  DataCell(Text(_num(r.amount))),
                                ]))
                            .toList(),
                      ),
                    ),
                  ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.only(top: 8, right: 12),
                    child: Text(
                      'الإجمالي: ${_num(_total)} \$',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _dateChip({
    required String label,
    required DateTime value,
    required VoidCallback onTap,
  }) {
    return ActionChip(
      avatar: const Icon(Icons.event_rounded, size: 18),
      label: Text('$label: ${_formatDate(value)}'),
      onPressed: onTap,
    );
  }
}

String _valueLabel(ProfitDistributionPreview r) {
  if (r.shareValue == null) return '—';
  switch (r.shareType) {
    case ShareModel.percentage:
      return '${_num(r.shareValue!)}%';
    case ShareModel.shares:
      return '${_num(r.shareValue!)} سهم';
    case ShareModel.salary:
      return 'راتب ${_num(r.shareValue!)}';
    case ShareModel.mixed:
      return 'مختلط ${_num(r.shareValue!)}';
  }
}

String _num(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(2);
}

String _formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
