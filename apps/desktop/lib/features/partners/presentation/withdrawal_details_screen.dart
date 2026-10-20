import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة تفاصيل طلب سحب (W7.4) — سطح المكتب.
///
/// تعرض كل حقول `partner_withdrawals` + سجل التدقيق الخاص بهذا السحب من
/// `partner_audit` + أزرار الإجراءات المتاحة لحالته (بنفس منطق القائمة:
/// pending = موافقة/رفض، approved = دفع، وإلخّ عرض فقط).
///
/// بعد إجراء ناجح تُغلق الشاشة بـ`true` فتعيد القائمة تحميل نفسها (لا توجد
/// قراءة مفردة للسحب في المستودع، والكائن المعروض سيصبح قديماً).
class WithdrawalDetailsScreen extends ConsumerStatefulWidget {
  const WithdrawalDetailsScreen({super.key, required this.withdrawal});

  /// السحب المعروض.
  final PartnerWithdrawal withdrawal;

  @override
  ConsumerState<WithdrawalDetailsScreen> createState() =>
      _WithdrawalDetailsScreenState();
}

class _WithdrawalDetailsScreenState
    extends ConsumerState<WithdrawalDetailsScreen> {
  List<PartnerAuditEntry> _audit = const [];
  Map<String, String> _partnerNames = const {};
  Map<String, String> _userNames = const {};
  Map<String, ProfitDistribution> _distributions = const {};

  bool _loading = false;
  bool _submitting = false;
  String? _error;

  PartnerWithdrawal get _w => widget.withdrawal;
  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';
  String get _uid => ref.read(authProvider).currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _load();
    _loadContext();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await ref
          .read(partnerWithdrawalRepositoryProvider)
          .getPartnerAudit(partnerId: _w.partnerId);
      if (!mounted) return;
      setState(() => _audit = entries.where(_belongsTo).toList());
    } catch (e) {
      if (mounted) setState(() => _error = _arabicError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// أسماء الشريك/المستخدمين/التوزيع للعرض — سياق ثانوي، الفشل يُطبع
  /// وتُعرض المعرّفات كما هي بدل إسقاط الشاشة.
  Future<void> _loadContext() async {
    try {
      final partners = await ref.read(partnerRepositoryProvider).getPartners();
      final users = _farmId.isEmpty
          ? await ref.read(userAdminRepositoryProvider).getAllUsers()
          : await ref.read(userAdminRepositoryProvider).getUsers(_farmId);
      final dists = _farmId.isEmpty
          ? const <ProfitDistribution>[]
          : await ref
              .read(partnershipRepositoryProvider)
              .getDistributions(farmId: _farmId);
      if (!mounted) return;
      setState(() {
        _partnerNames = {for (final p in partners) p.id!: p.name};
        _userNames = {for (final u in users) u.uid: u.name};
        _distributions = {for (final d in dists) d.id: d};
      });
    } catch (e) {
      debugPrint('madjana: withdrawal details context load skipped: $e');
    }
  }

  /// هل السطر من هذا السحب؟
  ///
  /// كلا مسارَي محفّز W7.4 (الطلب في INSERT والتغيير في UPDATE) يخزّن
  /// `withdrawal_id` في `new_values`، فالطابقة مباشرة بلا اعتمادٍ زمني.
  bool _belongsTo(PartnerAuditEntry e) =>
      e.newValues?['withdrawal_id']?.toString() == _w.id;

  // ─────────────── الإجراءات (بنفس منطق القائمة) ───────────────

  Future<void> _approve() async {
    if (_uid.isEmpty) {
      _snack('لا يوجد مستخدم مُتصل لتسجيل المعتمد');
      return;
    }
    final ok = await _confirm(
      'موافقة على السحب',
      'سيُعتمد سحب ${_num(_w.amount)} ${_currencyLabel(_w.currency)}. '
      'المتابعة؟',
    );
    if (ok != true) return;
    setState(() => _submitting = true);
    try {
      await ref.read(partnerWithdrawalRepositoryProvider).approveWithdrawal(
            withdrawalId: _w.id,
            approverId: _uid,
          );
      if (!mounted) return;
      _snack('تم اعتماد السحب');
      Navigator.pop(context, true);
    } catch (e) {
      _snack(_arabicError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _reject() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _RejectionDialog(),
    );
    if (reason == null || !mounted) return;
    final ok = await _confirm(
      'رفض السحب',
      'سيُرفض سحب ${_num(_w.amount)} ${_currencyLabel(_w.currency)}. '
      'السبب: $reason. المتابعة؟',
    );
    if (ok != true) return;
    setState(() => _submitting = true);
    try {
      await ref.read(partnerWithdrawalRepositoryProvider).rejectWithdrawal(
            withdrawalId: _w.id,
            rejectionReason: reason,
          );
      if (!mounted) return;
      _snack('تم رفض السحب');
      Navigator.pop(context, true);
    } catch (e) {
      _snack(_arabicError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _pay() async {
    final ok = await _confirm(
      'صرف السحب',
      'سيُسجَّل سحب ${_num(_w.amount)} ${_currencyLabel(_w.currency)} '
      'كمصروف (مدفوع). المتابعة؟',
    );
    if (ok != true) return;
    setState(() => _submitting = true);
    try {
      await ref.read(partnerWithdrawalRepositoryProvider).markPaid(
            withdrawalId: _w.id,
          );
      if (!mounted) return;
      _snack('تم صرف السحب');
      Navigator.pop(context, true);
    } catch (e) {
      _snack(_arabicError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
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
  // ─────────────── العرض ───────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // العنوان + الحالة + أزرار الإجراءات المتاحة.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'تفاصيل السحب',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              _WithdrawalStatusChip(status: _w.status),
              const SizedBox(width: 8),
              ..._actionButtons(),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: _fields(context),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(child: _auditSection(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// أزرار الإجراءات حسب الحالة (pending = موافقة/reject، approved = دفع).
  List<Widget> _actionButtons() {
    final buttons = <Widget>[];
    if (_w.status == PartnerWithdrawalStatus.pending) {
      buttons.add(
        FilledButton.tonalIcon(
          onPressed: _submitting ? null : _approve,
          icon: const Icon(Icons.check_rounded, size: 16),
          label: const Text('موافقة'),
        ),
      );
      buttons.add(const SizedBox(width: 6));
      buttons.add(
        OutlinedButton.icon(
          onPressed: _submitting ? null : _reject,
          icon: const Icon(Icons.close_rounded, size: 16),
          label: const Text('رفض'),
        ),
      );
    } else if (_w.status == PartnerWithdrawalStatus.approved) {
      buttons.add(
        FilledButton.tonalIcon(
          onPressed: _submitting ? null : _pay,
          icon: const Icon(Icons.payments_rounded, size: 16),
          label: const Text('دفع'),
        ),
      );
    }
    return buttons;
  }

  /// بطاقة حقول السحب كاملة.
  Widget _fields(BuildContext context) {
    final w = _w;
    final rows = <Widget>[
      _row(context, 'الشريك', _partnerLabel(w.partnerId)),
      _row(context, 'الحالة', w.status.label),
      _row(
          context,
          'المبلغ',
          '${_num(w.amount)} ${_currencyLabel(w.currency)}'),
      _row(context, 'تاريخ الطلب', _formatDateTime(w.requestedAt)),
      _row(context, 'الطالب', _userLabel(w.requestedBy)),
      _row(context, 'السبب', w.reason ?? '—'),
      _row(context, 'التوزيع المرتبط', _distLabel(w.distributionId)),
      _row(context, 'المراجع', _userLabel(w.reviewedBy)),
      _row(context, 'وقت المراجعة', _formatDateTime(w.reviewedAt)),
      _row(context, 'سبب الرفض', w.rejectionReason ?? '—'),
      _row(context, 'وقت الصرف', _formatDateTime(w.paidAt)),
      _row(context, 'طريقة الدفع', w.paymentMethod ?? '—'),
      _row(context, 'الملاحظات', w.notes ?? '—'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('حقول السحب',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        for (final r in rows) r,
      ],
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
  /// قسم سجل التدقيق الخاص بهذا السحب.
  Widget _auditSection(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.gpp_bad_rounded,
                size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 8),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      );
    }
    if (_audit.isEmpty) {
      return const Center(child: Text('لا يوجد سجل تدقيق لهذا السحب'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('سجل التدقيق',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            child: DataTable(
              columns: const [
                DataColumn(label: Text('الإجراء')),
                DataColumn(label: Text('المنفّذ')),
                DataColumn(label: Text('وقت التنفيذ')),
                DataColumn(label: Text('التفاصيل')),
              ],
              rows: _audit
                  .map((e) => DataRow(cells: [
                        DataCell(Text(_actionLabel(e.action))),
                        DataCell(Text(_userLabel(e.changedBy))),
                        DataCell(Text(_formatDateTime(e.changedAt))),
                        DataCell(Text(_auditDetails(e))),
                      ]))
                  .toList(),
            ),
          ),
        ),
      ],
    );
  }

  String _actionLabel(String action) => switch (action) {
        'withdrawal_requested' => 'طلب سحب',
        'withdrawal_approved' => 'اعتماد',
        'withdrawal_rejected' => 'رفض',
        'withdrawal_paid' => 'صرف',
        _ => action,
      };

  /// نص مختصر لسطر التدقيق بحسب الإجراء (مبلغ/سبب/حالة/طريقة دفع).
  String _auditDetails(PartnerAuditEntry e) {
    final parts = <String>[];
    final nv = e.newValues ?? const <String, dynamic>{};
    if (e.action == 'withdrawal_requested') {
      final amount = _toDouble(nv['amount']);
      if (amount != null) {
        parts.add('المبلغ: ${_num(amount)} ${_currencyLabel(nv['currency']?.toString() ?? 'dollar')}');
      }
      final reason = nv['reason']?.toString();
      if (reason != null && reason.isNotEmpty) parts.add('السبب: $reason');
    }
    final status = nv['status']?.toString();
    if (status != null && status.isNotEmpty) {
      parts.add('الحالة: ${PartnerWithdrawalStatus.fromName(status).label}');
    }
    final rejection = nv['rejection_reason']?.toString();
    if (rejection != null && rejection.isNotEmpty) {
      parts.add('سبب الرفض: $rejection');
    }
    final method = nv['payment_method']?.toString();
    if (method != null && method.isNotEmpty) {
      parts.add('طريقة الدفع: $method');
    }
    final oldStatus = e.oldValues?['status']?.toString();
    if (oldStatus != null && oldStatus.isNotEmpty) {
      parts.add('كانت: ${PartnerWithdrawalStatus.fromName(oldStatus).label}');
    }
    return parts.isEmpty ? '—' : parts.join(' • ');
  }
  String _partnerLabel(String partnerId) =>
      _partnerNames[partnerId] ?? partnerId;

  /// اسم المستخدم أو معرّفه المختصر إن لم تصل الأسماء.
  String _userLabel(String? uid) {
    if (uid == null || uid.isEmpty) return '—';
    final name = _userNames[uid];
    if (name != null && name.isNotEmpty) return name;
    return uid.length > 12 ? '${uid.substring(0, 8)}…' : uid;
  }

  /// وسم التوزيع المرتبط (أو «—» حين لا ربط).
  String _distLabel(String? distributionId) {
    if (distributionId == null || distributionId.isEmpty) return '—';
    final d = _distributions[distributionId];
    if (d == null) return distributionId;
    final base = (d.label == null || d.label!.isEmpty)
        ? '${_formatDate(d.periodStart)} → ${_formatDate(d.periodEnd)}'
        : d.label!;
    return '$base • ${d.status.label}';
  }

  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  String _num(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }

  String _currencyLabel(String code) => code == 'lira' ? 'ليرة' : 'دولار';

  String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String _formatDateTime(DateTime? d) {
    if (d == null) return '—';
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${_formatDate(d)} $hh:$mm';
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

/// شارة حالة السحب الملوّنة (نفس نمط القائمة).
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

