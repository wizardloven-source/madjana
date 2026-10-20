import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة إنشاء طلب سحب جديد (W7.4) — سطح المكتب.
///
/// تكتب صفّاً جديداً في `partner_withdrawals` بحالة `pending` دائماً
/// (السلّم يفرضه الخادم). الحقول:
///
/// * شريك (إلزامي) + مبلغ > 0 (إلزامي) + عملة (`dollar`/`lira` — وسم؛
///   المبالغ بالدولار دائماً M29v2) + سبب (اختياري) + ربط توزيع (اختياري:
///   تركه فارغاً يعني طلباً مستقلاً).
///
/// [requestedBy] هو معرّف المُتصل الحالي (`users.id`، العمود NOT NULL بلا
/// افتراض). كل الأخطاء تُعرض بـ[_arabicError] بعد [_confirm] (نمط W7.3).
class CreateWithdrawalScreen extends ConsumerStatefulWidget {
  const CreateWithdrawalScreen({super.key});

  @override
  ConsumerState<CreateWithdrawalScreen> createState() =>
      _CreateWithdrawalScreenState();
}

class _CreateWithdrawalScreenState
    extends ConsumerState<CreateWithdrawalScreen> {
  final _amountCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();

  List<PartnerModel> _partners = const [];
  List<ProfitDistribution> _distributions = const [];

  String? _partnerId;
  String? _distributionId;
  String _currency = 'dollar';

  bool _submitting = false;
  String? _error;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';
  String get _uid => ref.read(authProvider).currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _loadContext();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  /// الشركاء والتوزيعات — سياق ثانوي: فشلها يُطبع وتبقى القوائم فارغة
  /// (وُلد منها رسالة تحقّق عند الإنشاء بدل الإسقاط الصامت).
  Future<void> _loadContext() async {
    try {
      final partners = await ref.read(partnerRepositoryProvider).getPartners();
      if (!mounted) return;
      setState(() {
        _partners = partners;
        if (partners.length == 1) _partnerId = partners.first.id;
      });
    } catch (e) {
      debugPrint('madjana: create withdrawal partners load failed: $e');
    }

    if (_farmId.isEmpty) return;
    try {
      final dists = await ref
          .read(partnershipRepositoryProvider)
          .getDistributions(farmId: _farmId);
      if (!mounted) return;
      setState(() => _distributions = dists);
    } catch (e) {
      debugPrint('madjana: create withdrawal distributions load failed: $e');
    }
  }

  Future<void> _submit() async {
    if (_farmId.isEmpty) {
      setState(() => _error = 'لا مدجنة فعّالة');
      return;
    }
    if (_uid.isEmpty) {
      setState(() => _error = 'لا يوجد مستخدم مُتصل');
      return;
    }
    final partnerId = _partnerId;
    if (partnerId == null) {
      setState(() => _error = 'اختر الشريك');
      return;
    }
    final amount = double.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'أدخل مبلغاً صحيحاً أكبر من صفر');
      return;
    }

    final ok = await _confirm(
      'إنشاء طلب سحب',
      'سيُنشأ طلب سحب بمبلغ ${_num(amount)} ${_currencyLabel(_currency)} '
      'لصالح ${_nameOf(partnerId)} بحالة «قيد المراجعة». المتابعة؟',
    );
    if (ok != true) return;

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final created =
          await ref.read(partnerWithdrawalRepositoryProvider).createWithdrawal(
                partnerId: partnerId,
                farmId: _farmId,
                amount: amount,
                requestedBy: _uid,
                distributionId: _distributionId,
                reason: _reasonCtrl.text.trim().isEmpty
                    ? null
                    : _reasonCtrl.text.trim(),
                currency: _currency,
              );
      if (!mounted) return;
      Navigator.pop(context, created);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _arabicError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _nameOf(String partnerId) {
    for (final p in _partners) {
      if (p.id == partnerId) return p.name;
    }
    return '—';
  }

  // ─────────────── أدوات مشتركة مع W7.3 ───────────────

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
        case 'PARTNER_NOT_FOUND':
          return 'الشريك غير موجود';
        case 'WITHDRAWAL_DISTRIBUTION_MISMATCH':
          return 'التوزيع المختار لا يخص هذه المدجنة';
        case 'INVALID_STATUS_TRANSITION':
          return 'لا يمكن الانتقال من هذه الحالة';
        default:
          return e.message;
      }
    }
    return e.toString().replaceFirst('Exception: ', '');
  }
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('طلب سحب جديد'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Row(
                children: [
                  Icon(Icons.payments_rounded,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'طلب سحب جديد',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // الشريك + العملة.
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      initialValue: _partnerId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'الشريك (إلزامي)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null, child: Text('— اختر الشريك —')),
                        for (final p in _partners)
                          DropdownMenuItem<String?>(
                              value: p.id, child: Text(p.name)),
                      ],
                      onChanged: (v) => setState(() => _partnerId = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _currency,
                      decoration: const InputDecoration(
                        labelText: 'العملة',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem<String>(
                            value: 'dollar', child: Text('دولار (USD)')),
                        DropdownMenuItem<String>(
                            value: 'lira', child: Text('ليرة (Lira)')),
                      ],
                      onChanged: (v) =>
                          setState(() => _currency = v ?? 'dollar'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'المبلغ (إلزامي)',
                  prefixIcon: Icon(Icons.attach_money_rounded),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reasonCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'السبب (اختياري)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              // ربط توزيع اختياري — تركه فارغاً ينتج طلباً مستقلاً.
              DropdownButtonFormField<String?>(
                initialValue: _distributionId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'ربط بتوزيع (اختياري)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('بدون ربط (طلب مستقل)')),
                  for (final d in _distributions)
                    DropdownMenuItem<String?>(
                        value: d.id, child: Text(_distLabel(d))),
                ],
                onChanged: (v) => setState(() => _distributionId = v),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color:
                        theme.colorScheme.errorContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_error!,
                      style: TextStyle(color: theme.colorScheme.error)),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _submitting ? null : _submit,
                    icon: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded, size: 18),
                    label: const Text('إنشاء'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed:
                        _submitting ? null : () => Navigator.pop(context),
                    child: const Text('إلغاء'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ));
  }

  /// وسم التوزيع في القائمة المنسدلة: الوسم أو الفترة + الحالة.
  String _distLabel(ProfitDistribution d) {
    final base = (d.label == null || d.label!.isEmpty)
        ? '${_formatDate(d.periodStart)} → ${_formatDate(d.periodEnd)}'
        : d.label!;
    return '$base • ${d.status.label}';
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


}
