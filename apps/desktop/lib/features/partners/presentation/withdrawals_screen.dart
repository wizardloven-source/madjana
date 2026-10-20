import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';
import 'create_withdrawal_screen.dart';
import 'withdrawal_details_screen.dart';

/// شاشة سحوبات الشركاء (W7.4) — سطح المكتب.
///
/// * القائمة تُقرأ من `partner_withdrawals`؛ الرؤية تحدّدها RLS (مدير المزرعة
///   يرى سحوبات مزرعته، ومدير النظام الكل، والشريك طلباته).
/// * «موافقة» تستدعي RPC `approve_withdrawal` (M24)؛ «رفض» (مع سبب إلزامي)
///   و«دفع» تحديثات مباشرة يفرض سلّمها الخادم (`guard_withdrawal_status`).
/// * كل إجراء يمرّ من [_confirm] وكل خطأ يُعرض بـ[_arabicError] (نمط W7.3).
///
/// الشريط العلوي يعرض رصيد الشريك المتاح من RPC `partner_summary` عند اختيار
/// شريك بعينه، وإلا مجاميع القائمة الحالية (pending+approved / paid).
/// المبالغ بالدولار دائماً (M29v2)؛ عمود `currency` وسم فقط.
class WithdrawalsScreen extends ConsumerStatefulWidget {
  const WithdrawalsScreen({super.key});

  @override
  ConsumerState<WithdrawalsScreen> createState() => _WithdrawalsScreenState();
}

class _WithdrawalsScreenState extends ConsumerState<WithdrawalsScreen> {
  List<PartnerWithdrawal> _all = const [];
  List<PartnerModel> _partners = const [];
  Map<String, String> _partnerNames = const {};

  /// فلترة الحالة من التبويبات (`null` = الكل).
  PartnerWithdrawalStatus? _statusFilter;

  /// فلترة شريك محدّد؛ اختيارها يجلب ملخّصه (الرصيد المتاح).
  String? _partnerId;

  PartnerSummary? _summary;

  bool _loading = false;
  bool _submitting = false;
  String? _error;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';
  String get _uid => ref.read(authProvider).currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _loadPartners();
    _load();
  }

  /// أسماء الشركاء — سياق ثانوي، فشلها لا يُسقط القائمة.
  Future<void> _loadPartners() async {
    try {
      final partners = await ref.read(partnerRepositoryProvider).getPartners();
      if (!mounted) return;
      setState(() {
        _partners = partners;
        _partnerNames = {for (final p in partners) p.id!: p.name};
      });
    } catch (e) {
      debugPrint('madjana: withdrawals partners load failed: $e');
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows =
          await ref.read(partnerWithdrawalRepositoryProvider).getWithdrawals(
                farmId: _farmId.isEmpty ? null : _farmId,
                partnerId: _partnerId,
              );
      if (!mounted) return;
      setState(() => _all = rows);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _arabicError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    await _loadSummary();
  }

  /// ملخّص الشريك المحدّد (`partner_summary` مع حساب بديل) — سياق ثانوي:
  /// فشله يُطبع ويُبقي القائمة والمجاميع كما هي.
  Future<void> _loadSummary() async {
    final partnerId = _partnerId;
    if (partnerId == null) {
      if (mounted) setState(() => _summary = null);
      return;
    }
    try {
      final summary = await ref
          .read(partnerWithdrawalRepositoryProvider)
          .getPartnerSummary(partnerId: partnerId);
      if (!mounted) return;
      setState(() => _summary = summary);
    } catch (e) {
      debugPrint('madjana: partner summary load skipped: $e');
      if (mounted) setState(() => _summary = null);
    }
  }

  List<PartnerWithdrawal> get _filtered {
    final f = _statusFilter;
    if (f == null) return _all;
    return _all.where((w) => w.status == f).toList();
  }

  /// مجموع المعلّق (pending + approved) في القائمة الحالية.
  double get _sumPending => _all
      .where((w) =>
          w.status == PartnerWithdrawalStatus.pending ||
          w.status == PartnerWithdrawalStatus.approved)
      .fold(0.0, (sum, w) => sum + w.amount);

  /// مجموع المصروف (paid) في القائمة الحالية.
  double get _sumPaid => _all
      .where((w) => w.status == PartnerWithdrawalStatus.paid)
      .fold(0.0, (sum, w) => sum + w.amount);
  // ─────────────── الإجراءات ───────────────

  Future<void> _approve(PartnerWithdrawal w) async {
    if (_uid.isEmpty) {
      _snack('لا يوجد مستخدم مُتصل لتسجيل المعتمد');
      return;
    }
    final ok = await _confirm(
      'موافقة على السحب',
      'سيُعتمد سحب ${_num(w.amount)} ${_currencyLabel(w.currency)} '
      'لصالح ${_name(w.partnerId)}. المتابعة؟',
    );
    if (ok != true) return;
    setState(() => _submitting = true);
    try {
      await ref.read(partnerWithdrawalRepositoryProvider).approveWithdrawal(
            withdrawalId: w.id,
            approverId: _uid,
          );
      _snack('تم اعتماد السحب');
      await _load();
    } catch (e) {
      _snack(_arabicError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _reject(PartnerWithdrawal w) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _RejectionDialog(),
    );
    if (reason == null || !mounted) return;
    final ok = await _confirm(
      'رفض السحب',
      'سيُرفض سحب ${_num(w.amount)} ${_currencyLabel(w.currency)} '
      'لصالح ${_name(w.partnerId)}. السبب: $reason. المتابعة؟',
    );
    if (ok != true) return;
    setState(() => _submitting = true);
    try {
      await ref.read(partnerWithdrawalRepositoryProvider).rejectWithdrawal(
            withdrawalId: w.id,
            rejectionReason: reason,
          );
      _snack('تم رفض السحب');
      await _load();
    } catch (e) {
      _snack(_arabicError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _pay(PartnerWithdrawal w) async {
    final ok = await _confirm(
      'صرف السحب',
      'سيُسجَّل سحب ${_num(w.amount)} ${_currencyLabel(w.currency)} '
      'لصالح ${_name(w.partnerId)} كمصروف (مدفوع). المتابعة؟',
    );
    if (ok != true) return;
    setState(() => _submitting = true);
    try {
      await ref.read(partnerWithdrawalRepositoryProvider).markPaid(
            withdrawalId: w.id,
          );
      _snack('تم صرف السحب');
      await _load();
    } catch (e) {
      _snack(_arabicError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _openCreate() async {
    final created = await Navigator.of(context).push<PartnerWithdrawal>(
      MaterialPageRoute(builder: (_) => const CreateWithdrawalScreen()),
    );
    if (created == null || !mounted) return;
    _snack('تم إنشاء طلب السحب بانتظار المراجعة');
    await _load();
  }

  Future<void> _openDetails(PartnerWithdrawal w) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => WithdrawalDetailsScreen(withdrawal: w)),
    );
    if (changed != true || !mounted) return;
    await _load();
  }
  // ─────────────── أدوات مشتركة مع W7.3 ───────────────

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _confirm(String title, String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('إلغاء')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('تأكيد')),
            ],
          ),
        ) ??
        false;
  }

  /// يحوّل أخطاء الكتابة ([SyncFailure]) إلى رسالة عربية واضحة.
  String _arabicError(Object e) {
    if (e is SyncFailure) {
      switch (e.code) {
        case 'AUTHORIZATION_DENIED':
          return 'أنت لا تملك صلاحية هذه العملية';
        case 'INVALID_STATUS_TRANSITION':
          return 'لا يمكن الانتقال من هذه الحالة (حدّث القائمة)';
        case 'WITHDRAWAL_NOT_FOUND':
          return 'السحب غير موجود';
        case 'WITHDRAWAL_CONFLICT':
          return 'تغيّرت حالة السحب — حدّث القائمة';
        case 'REJECTION_REASON_REQUIRED':
          return 'سبب الرفض إلزامي';
        case 'PARTNER_NOT_FOUND':
          return 'الشريك غير موجود';
        default:
          return e.message;
      }
    }
    return e.toString().replaceFirst('Exception: ', '');
  }

  String _name(String partnerId) => _partnerNames[partnerId] ?? '—';

  // ─────────────── العرض ───────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _filtered;

    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // الشريط العلوي: الرصيد + إجراءات القائمة.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_summary != null) ...[
                Chip(
                  avatar: const Icon(Icons.account_balance_wallet_rounded,
                      size: 18),
                  label: Text('الرصيد المتاح: ${_num(_summary!.available)} \$'),
                ),
                Chip(label: Text('معلّق: ${_num(_summary!.pending)} \$')),
                Chip(label: Text('مدفوع: ${_num(_summary!.paid)} \$')),
              ] else ...[
                Chip(
                  avatar: const Icon(Icons.payments_rounded, size: 18),
                  label: Text('الطلبات: ${_all.length}'),
                ),
                Chip(label: Text('المعلّق: ${_num(_sumPending)} \$')),
                Chip(label: Text('المصروف: ${_num(_sumPaid)} \$')),
              ],
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _submitting ? null : _openCreate,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('طلب سحب جديد'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('تحديث'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // فلترة: شريك (يجلب ملخّصه) + تبويبات الحالة.
          Row(
            children: [
              SizedBox(
                width: 320,
                child: DropdownButtonFormField<String?>(
                  initialValue: _partnerId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'الشريك',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('كل الشركاء')),
                    for (final p in _partners)
                      DropdownMenuItem<String?>(
                          value: p.id, child: Text(p.name)),
                  ],
                  onChanged: (v) {
                    setState(() => _partnerId = v);
                    _load();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<PartnerWithdrawalStatus?>(
                    segments: const [
                      ButtonSegment<PartnerWithdrawalStatus?>(
                          value: null, label: Text('الكل')),
                      ButtonSegment<PartnerWithdrawalStatus?>(
                          value: PartnerWithdrawalStatus.pending,
                          label: Text('قيد الانتظار')),
                      ButtonSegment<PartnerWithdrawalStatus?>(
                          value: PartnerWithdrawalStatus.approved,
                          label: Text('معتمد')),
                      ButtonSegment<PartnerWithdrawalStatus?>(
                          value: PartnerWithdrawalStatus.paid,
                          label: Text('مدفوع')),
                      ButtonSegment<PartnerWithdrawalStatus?>(
                          value: PartnerWithdrawalStatus.rejected,
                          label: Text('مرفوض')),
                    ],
                    selected: {_statusFilter},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) =>
                        setState(() => _statusFilter = s.first),
                  ),
                ),
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
          else if (visible.isEmpty)
            const Expanded(
              child: Center(child: Text('لا توجد سحوبات مطابقة')),
            )
          else
            Expanded(
              child: SingleChildScrollView(
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('الشريك')),
                    DataColumn(label: Text('المبلغ')),
                    DataColumn(label: Text('العملة')),
                    DataColumn(label: Text('التاريخ')),
                    DataColumn(label: Text('الحالة')),
                    DataColumn(label: Text('إجراءات')),
                  ],
                  rows: visible
                      .map((w) => DataRow(cells: [
                            DataCell(Text(_name(w.partnerId))),
                            DataCell(Text(_num(w.amount))),
                            DataCell(Text(_currencyLabel(w.currency))),
                            DataCell(Text(w.requestedAt == null
                                ? '—'
                                : _formatDate(w.requestedAt!))),
                            DataCell(_WithdrawalStatusChip(status: w.status)),
                            DataCell(_actions(w)),
                          ]))
                      .toList(),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

  /// أزرار الصف حسب الحالة: pending = موافقة/رفض، approved = دفع، غير ذلك
  /// عرض فقط (زر التفاصيل متاح في كل الصفوف).
  Widget _actions(PartnerWithdrawal w) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (w.status == PartnerWithdrawalStatus.pending) ...[
          FilledButton.tonalIcon(
            onPressed: _submitting ? null : () => _approve(w),
            icon: const Icon(Icons.check_rounded, size: 16),
            label: const Text('موافقة'),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            onPressed: _submitting ? null : () => _reject(w),
            icon: const Icon(Icons.close_rounded, size: 16),
            label: const Text('رفض'),
          ),
        ] else if (w.status == PartnerWithdrawalStatus.approved)
          FilledButton.tonalIcon(
            onPressed: _submitting ? null : () => _pay(w),
            icon: const Icon(Icons.payments_rounded, size: 16),
            label: const Text('دفع'),
          ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'تفاصيل',
          icon: const Icon(Icons.info_outline),
          onPressed: () => _openDetails(w),
        ),
      ],
    );
}
}


/// حوار سبب الرفض — إلزامي (قيد CHECK: `rejected` تتطلب `rejection_reason`).
class _RejectionDialog extends StatefulWidget {
  const _RejectionDialog();

  @override
  State<_RejectionDialog> createState() => _RejectionDialogState();
}

class _RejectionDialogState extends State<_RejectionDialog> {
  String _reason = '';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('رفض السحب'),
      content: SizedBox(
        width: 420,
        child: TextField(
          autofocus: true,
          maxLines: 3,
          onChanged: (v) => setState(() => _reason = v.trim()),
          decoration: const InputDecoration(
            labelText: 'سبب الرفض (إلزامي)',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed:
              _reason.isEmpty ? null : () => Navigator.pop(context, _reason),
          child: const Text('متابعة'),
        ),
      ],
    );
  }
}

/// شارة حالة السحب الملوّنة (نمط `_StatusChip` في شاشة الشركاء).
class _WithdrawalStatusChip extends StatelessWidget {
  final PartnerWithdrawalStatus status;

  const _WithdrawalStatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      PartnerWithdrawalStatus.pending => Colors.orange,
      PartnerWithdrawalStatus.approved => Colors.blue,
      PartnerWithdrawalStatus.paid => Colors.green,
      PartnerWithdrawalStatus.rejected => Colors.red,
      PartnerWithdrawalStatus.cancelled => Colors.grey,
    };
    return Chip(
      label: Text(status.label),
      visualDensity: VisualDensity.compact,
      backgroundColor: color.withValues(alpha: 0.12),
      side: BorderSide(color: color.withValues(alpha: 0.4)),
    );
  }
}

String _currencyLabel(String code) => code == 'lira' ? 'ليرة' : 'دولار';

String _num(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(2);
}

String _formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

