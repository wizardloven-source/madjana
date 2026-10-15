import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

/// شاشة إدارة الشركاء (W6) — سطح المكتب.
///
/// قائمة/إضافة/تعديل/حذف منطقي (soft). الكتابة على `partners` محصورة بـ
/// `is_system_admin()` في RLS؛ أما المدير فيرى الشركاء الذين لهم أعمال في
/// مدجنته فقط، وقد ترفض القاعدة إنشاء شريك جديد من حساب مدير — والرسالة
/// تُعرض كما هي بدل إخفائها.
class PartnersScreen extends ConsumerStatefulWidget {
  const PartnersScreen({super.key});

  @override
  ConsumerState<PartnersScreen> createState() => _PartnersScreenState();
}

class _PartnersScreenState extends ConsumerState<PartnersScreen> {
  List<PartnerModel> _all = const [];
  bool _loading = true;
  String? _error;
  String _search = '';
  bool _showDeleted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(partnerRepositoryProvider);
      final partners = _showDeleted
          ? await repo.getPartnersIncludingDeleted()
          : await repo.getPartners();
      if (!mounted) return;
      setState(() => _all = partners);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<PartnerModel> get _filtered {
    if (_search.isEmpty) return _all;
    final q = _search.trim();
    return _all
        .where((p) =>
            p.name.contains(q) ||
            (p.phone ?? '').contains(q) ||
            (p.nationalId ?? '').contains(q))
        .toList();
  }

  Future<void> _showPartnerDialog({PartnerModel? partner}) async {
    final result = await showDialog<PartnerModel>(
      context: context,
      builder: (_) => _PartnerDialog(partner: partner),
    );
    if (result == null) return;
    try {
      await ref.read(partnerRepositoryProvider).save(result);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(partner == null ? 'تمت إضافة الشريك' : 'تم تعديل الشريك')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _softDelete(PartnerModel partner) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف شريك'),
        content: Text('هل تريد حذف "${partner.name}"؟ (حذف منطقي قابل للاستعادة)'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تأكيد')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(partnerRepositoryProvider).softDelete(partner.id!);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _restore(PartnerModel partner) async {
    try {
      await ref.read(partnerRepositoryProvider).restore(partner.id!);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
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
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Chip(
                avatar: const Icon(Icons.handshake_rounded, size: 18),
                label: Text(_showDeleted
                    ? 'الكل: ${_all.length} (${_countDeletedIn(_all)} محذوف)'
                    : 'عدد الشركاء: ${_all.length}'),
              ),
              FilterChip(
                label: const Text('إظهار المحذوفين'),
                selected: _showDeleted,
                onSelected: (v) {
                  setState(() => _showDeleted = v);
                  _load();
                },
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _showPartnerDialog(),
                icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                label: const Text('شريك جديد'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('تحديث'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 340,
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                labelText: 'بحث بالاسم أو الهاتف أو الرقم الوطني...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off_rounded,
                        size: 48, color: Theme.of(context).colorScheme.error),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              ),
            )
          else if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_filtered.isEmpty)
            const Expanded(child: Center(child: Text('لا يوجد شركاء')))
          else
            Expanded(
              child: SingleChildScrollView(
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('الاسم')),
                    DataColumn(label: Text('الهاتف')),
                    DataColumn(label: Text('الطبيعة')),
                    DataColumn(label: Text('نموذج الحصة')),
                    DataColumn(label: Text('القيمة')),
                    DataColumn(label: Text('الحالة')),
                    DataColumn(label: Text('إجراءات')),
                  ],
                  rows: _filtered.map((p) {
                    final deleted = p.isDeleted;
                    return DataRow(
                      color: deleted
                          ? WidgetStatePropertyAll(
                              Theme.of(context).colorScheme.surfaceContainerHighest)
                          : null,
                      cells: [
                        DataCell(Text(
                          p.name,
                          style: TextStyle(
                            fontWeight: deleted ? FontWeight.w400 : FontWeight.w600,
                            decoration:
                                deleted ? TextDecoration.lineThrough : null,
                          ),
                        )),
                        DataCell(Text(p.phone ?? '—')),
                        DataCell(Text(p.partnerRole.label)),
                        DataCell(Text(p.shareModel.label)),
                        DataCell(Text(_shareSummary(p))),
                        DataCell(_StatusChip(status: p.status, deleted: deleted)),
                        DataCell(Row(children: [
                          if (deleted)
                            IconButton(
                              tooltip: 'استعادة',
                              icon: const Icon(Icons.restore_rounded,
                                  color: Colors.green),
                              onPressed: () => _restore(p),
                            )
                          else ...[
                            IconButton(
                              tooltip: 'تعديل',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _showPartnerDialog(partner: p),
                            ),
                            IconButton(
                              tooltip: 'حذف',
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.red),
                              onPressed: () => _softDelete(p),
                            ),
                          ],
                        ])),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// عدّاد بسيط مشترك.
int _countDeletedIn(List<PartnerModel> list) =>
    list.where((p) => p.isDeleted).length;

String _shareSummary(PartnerModel p) {
  switch (p.shareModel) {
    case ShareModel.percentage:
      return p.percentage == null ? '—' : '${_num(p.percentage!)}%';
    case ShareModel.shares:
      return p.shares == null ? '—' : '${_num(p.shares!)} سهم';
    case ShareModel.salary:
      final period = p.salaryPeriod?.label ?? '';
      return p.salaryAmount == null ? '—' : '${_num(p.salaryAmount!)} / $period';
    case ShareModel.mixed:
      final parts = <String>[];
      if (p.salaryAmount != null) {
        parts.add('راتب ${_num(p.salaryAmount!)}');
      }
      if (p.percentage != null) parts.add('${_num(p.percentage!)}%');
      if (p.shares != null) parts.add('${_num(p.shares!)} سهم');
      return parts.isEmpty ? '—' : parts.join(' + ');
  }
}

String _num(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toString();
}

class _StatusChip extends StatelessWidget {
  final PartnerStatus status;
  final bool deleted;

  const _StatusChip({required this.status, required this.deleted});

  @override
  Widget build(BuildContext context) {
    if (deleted) {
      return const Chip(
        label: Text('محذوف'),
        visualDensity: VisualDensity.compact,
      );
    }
    final color = switch (status) {
      PartnerStatus.active => Colors.green,
      PartnerStatus.inactive => Colors.orange,
      PartnerStatus.suspended => Colors.red,
    };
    return Chip(
      label: Text(status.label),
      visualDensity: VisualDensity.compact,
      backgroundColor: color.withValues(alpha: 0.12),
      side: BorderSide(color: color.withValues(alpha: 0.4)),
    );
  }
}

/// حوار إضافة/تعديل شريك. يعيد [PartnerModel] عند الحفظ، أو null عند الإلغاء.
class _PartnerDialog extends StatefulWidget {
  final PartnerModel? partner;

  const _PartnerDialog({this.partner});

  @override
  State<_PartnerDialog> createState() => _PartnerDialogState();
}

class _PartnerDialogState extends State<_PartnerDialog> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _nationalId;
  late final TextEditingController _percentage;
  late final TextEditingController _shares;
  late final TextEditingController _salary;

  late PartnerStatus _status;
  late PartnerRole _role;
  late ShareModel _shareModel;
  late SalaryPeriod _salaryPeriod;
  late AppCurrency _currency;
  DateTime? _effectiveFrom;
  DateTime? _effectiveTo;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.partner;
    _name = TextEditingController(text: p?.name ?? '');
    _phone = TextEditingController(text: p?.phone ?? '');
    _nationalId = TextEditingController(text: p?.nationalId ?? '');
    _percentage = TextEditingController(
        text: p?.percentage == null ? '' : _num(p!.percentage!));
    _shares =
        TextEditingController(text: p?.shares == null ? '' : _num(p!.shares!));
    _salary = TextEditingController(
        text: p?.salaryAmount == null ? '' : _num(p!.salaryAmount!));
    _status = p?.status ?? PartnerStatus.active;
    _role = p?.partnerRole ?? PartnerRole.investor;
    _shareModel = p?.shareModel ?? ShareModel.percentage;
    _salaryPeriod = p?.salaryPeriod ?? SalaryPeriod.monthly;
    _currency = p?.currency ?? AppCurrency.dollar;
    _effectiveFrom = p?.effectiveFrom;
    _effectiveTo = p?.effectiveTo;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _nationalId.dispose();
    _percentage.dispose();
    _shares.dispose();
    _salary.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final initial = (isFrom ? _effectiveFrom : _effectiveTo) ?? _effectiveFrom ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    final date = DateTime(picked.year, picked.month, picked.day);
    setState(() {
      if (isFrom) {
        _effectiveFrom = date;
      } else {
        _effectiveTo = date;
      }
    });
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'اسم الشريك مطلوب');
      return;
    }

    final pct = double.tryParse(_percentage.text.trim());
    final shares = double.tryParse(_shares.text.trim());
    final salary = double.tryParse(_salary.text.trim());

    final model = PartnerModel(
      id: widget.partner?.id,
      userId: widget.partner?.userId,
      name: name,
      phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      nationalId:
          _nationalId.text.trim().isEmpty ? null : _nationalId.text.trim(),
      status: _status,
      partnerRole: _role,
      shareModel: _shareModel,
      percentage: (_shareModel == ShareModel.percentage ||
              _shareModel == ShareModel.mixed)
          ? pct
          : null,
      shares:
          (_shareModel == ShareModel.shares || _shareModel == ShareModel.mixed)
              ? shares
              : null,
      salaryAmount: (_shareModel == ShareModel.salary ||
              _shareModel == ShareModel.mixed)
          ? salary
          : null,
      salaryPeriod: (_shareModel == ShareModel.salary ||
              _shareModel == ShareModel.mixed)
          ? _salaryPeriod
          : null,
      currency: _currency,
      effectiveFrom: _effectiveFrom,
      effectiveTo: _effectiveTo,
    );

    if (!model.hasValidShareFields) {
      setState(() => _error =
          'حقول الحصة لا توافق النموذج المختار (تحقّق من النسبة/الأسهم/الراتب)');
      return;
    }
    if (_effectiveFrom != null &&
        _effectiveTo != null &&
        _effectiveTo!.isBefore(_effectiveFrom!)) {
      setState(() => _error = 'تاريخ النهاية يجب أن يكون بعد تاريخ البداية');
      return;
    }
    Navigator.pop(context, model);
  }

  @override
  Widget build(BuildContext context) {
    final showPct = _shareModel == ShareModel.percentage ||
        _shareModel == ShareModel.mixed;
    final showShares =
        _shareModel == ShareModel.shares || _shareModel == ShareModel.mixed;
    final showSalary =
        _shareModel == ShareModel.salary || _shareModel == ShareModel.mixed;

    return AlertDialog(
      title: Text(widget.partner == null ? 'شريك جديد' : 'تعديل الشريك'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                    labelText: 'اسم الشريك', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                        labelText: 'الهاتف', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _nationalId,
                    decoration: const InputDecoration(
                        labelText: 'الرقم الوطني', border: OutlineInputBorder()),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: _dropdown<PartnerRole>(
                    label: 'طبيعة الشريك',
                    value: _role,
                    items: PartnerRole.values,
                    itemLabel: (v) => v.label,
                    onChanged: (v) => setState(() => _role = v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _dropdown<PartnerStatus>(
                    label: 'الحالة',
                    value: _status,
                    items: PartnerStatus.values,
                    itemLabel: (v) => v.label,
                    onChanged: (v) => setState(() => _status = v),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: _dropdown<ShareModel>(
                    label: 'نموذج الحصة',
                    value: _shareModel,
                    items: ShareModel.values,
                    itemLabel: (v) => v.label,
                    onChanged: (v) => setState(() => _shareModel = v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _dropdown<AppCurrency>(
                    label: 'العملة',
                    value: _currency,
                    items: AppCurrency.values,
                    itemLabel: (v) => v.label,
                    onChanged: (v) => setState(() => _currency = v),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              if (showPct)
                TextField(
                  controller: _percentage,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'النسبة % (0–100)',
                      border: OutlineInputBorder()),
                ),
              if (showPct) const SizedBox(height: 12),
              if (showShares)
                TextField(
                  controller: _shares,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'عدد الأسهم', border: OutlineInputBorder()),
                ),
              if (showShares) const SizedBox(height: 12),
              if (showSalary)
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _salary,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'مبلغ الراتب',
                          border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _dropdown<SalaryPeriod>(
                      label: 'دورة الراتب',
                      value: _salaryPeriod,
                      items: SalaryPeriod.values,
                      itemLabel: (v) => v.label,
                      onChanged: (v) => setState(() => _salaryPeriod = v),
                    ),
                  ),
                ]),
              if (showSalary) const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: _dateField(
                    label: 'ساري من',
                    value: _effectiveFrom,
                    onPick: () => _pickDate(isFrom: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _dateField(
                    label: 'ساري حتى',
                    value: _effectiveTo,
                    onPick: () => _pickDate(isFrom: false),
                  ),
                ),
              ]),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.errorContainer.withValues(
                              alpha: 0.4,
                            ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.check_rounded, size: 18),
          label: const Text('حفظ'),
        ),
      ],
    );
  }

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) itemLabel,
    required void Function(T) onChanged,
  }) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
          labelText: label, border: const OutlineInputBorder()),
      items: items
          .map((v) => DropdownMenuItem<T>(value: v, child: Text(itemLabel(v))))
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  Widget _dateField({
    required String label,
    required DateTime? value,
    required VoidCallback onPick,
  }) {
    return InkWell(
      onTap: onPick,
      child: InputDecorator(
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
        child: Text(value == null ? '—' : _formatDate(value)),
      ),
    );
  }
}

String _formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
