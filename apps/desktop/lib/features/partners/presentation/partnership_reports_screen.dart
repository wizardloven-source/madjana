import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:collection/collection.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';
import '../widgets/simple_bar_chart.dart';
import 'profit_distribution_screen.dart';
import 'withdrawal_details_screen.dart';

/// شاشة تقارير الشراكة (W7.5) — سطح المكتب.
/// شاشة واحدة تحمل 4 تبويبات عبر [TabBar]. التبويب 1 مكتمل (التوزيعات).
/// التصدير: CSV فقط. الأخطاء عبر [SyncFailure] و[_arabicError].
class PartnershipReportsScreen extends ConsumerStatefulWidget {
  const PartnershipReportsScreen({super.key});

  @override
  ConsumerState<PartnershipReportsScreen> createState() =>
      _PartnershipReportsScreenState();
}

class _PartnershipReportsScreenState
    extends ConsumerState<PartnershipReportsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int _selectedTab = 0;

  List<_DistRow> _distRows = [];
  bool _distLoading = false;
  String? _distError;

  DateTime? _distFrom;
  DateTime? _distTo;
  ProfitDistributionStatus? _distStatusFilter;

  // ===== التبويب 2: السحوبات =====
  List<_WdRow> _wdRows = [];
  Map<String, PartnerWithdrawal> _wdById = {};
  bool _wdLoading = false;
  String? _wdError;
  DateTime? _wdFrom;
  DateTime? _wdTo;
  PartnerWithdrawalStatus? _wdStatusFilter;
  String? _wdPartnerFilter;
  List<PartnerModel> _partners = [];
  bool _partnersLoaded = false;

  // ===== التبويب 3: ملخص الشركاء =====
  List<_PartnerSummaryRow> _summaryRows = [];
  bool _summaryLoading = false;
  String? _summaryError;
  String? _summaryPartnerFilter;

  // ===== التبويب 4: الأداء =====
  List<_PerfPeriodRow> _perfPeriodRows = [];
  List<_PerfPartnerRow> _perfPartnerRows = [];
  bool _perfLoading = false;
  String? _perfError;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  final _loadedTabs = <int>{};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() => _selectedTab = _tabController.index);
        _loadTabIfNeeded(_tabController.index);
      }
    });
    _loadDistributions();
    _loadPartners();
  }

  Future<void> _loadTabIfNeeded(int index) async {
    if (_loadedTabs.contains(index)) return;
    switch (index) {
      case 1:
        _loadedTabs.add(1);
        await _loadWithdrawals();
        break;
      case 2:
        _loadedTabs.add(2);
        await _loadPartnershipSummary();
        break;
      case 3:
        _loadedTabs.add(3);
        await _loadPerformance();
        break;
    }
  }

  Future<void> _loadDistributions() async {
    if (_farmId.isEmpty) {
      setState(() => _distError = 'لا مدجنة فعّالة');
      return;
    }
    setState(() {
      _distLoading = true;
      _distError = null;
    });
    try {
      final supabase = ref.read(supabaseClientProvider);
      final distRows = await supabase
          .from('profit_distributions')
          .select('''
            id, period_start, period_end, label, status, total_revenue,
            total_expenses, net_profit, approved_by
          ''')
          .eq('farm_id', _farmId)
          .order('period_start', ascending: false);
      final detailRows = await supabase
          .from('profit_distribution_details')
          .select('distribution_id, partner_id')
          .eq('farm_id', _farmId);
      final partnerCounts = <String, int>{};
      for (final d in detailRows) {
        final distId = (d['distribution_id'] ?? '').toString();
        final partnerId = (d['partner_id'] ?? '').toString();
        if (distId.isEmpty || partnerId.isEmpty) continue;
        partnerCounts.update(distId, (v) => v + 1, ifAbsent: () => 1);
      }
      final rows = <_DistRow>[];
      for (final d in distRows) {
        final id = (d['id'] ?? '').toString();
        final ps = DateTime.tryParse(d['period_start']?.toString() ?? '');
        final pe = DateTime.tryParse(d['period_end']?.toString() ?? '');
        final status = ProfitDistributionStatus.fromName(d['status']?.toString());
        rows.add(_DistRow(
          id: id,
          period: _periodLabel(ps, pe),
          periodStart: ps,
          periodEnd: pe,
          totalRevenue: _toDouble(d['total_revenue']) ?? 0,
          totalExpenses: _toDouble(d['total_expenses']) ?? 0,
          netProfit: _toDouble(d['net_profit']) ?? 0,
          distributor: _nameOfUser((d['approved_by'] ?? '').toString()),
          status: status,
          partnerCount: partnerCounts[id] ?? 0,
        ));
      }
      if (!mounted) return;
      setState(() { _distRows = rows; _distLoading = false; });
    } catch (e) {
      debugPrint('madjana: report distributions load failed: $e');
      if (!mounted) return;
      setState(() { _distError = _arabicError(e); _distLoading = false; });
    }
  }

  /// يجلب قائمة الشركاء للمزرعة الحالية (لقوائم المنسدلة في التبويبين 2 و3).
  Future<void> _loadPartners() async {
    if (_farmId.isEmpty || _partnersLoaded) return;
    setState(() => _partnersLoaded = true);
    try {
      final supabase = ref.read(supabaseClientProvider);
      final rows = await supabase
          .from('partners')
          .select(
            'id, name, share_model, percentage, shares, salary_amount, salary_period, currency, status, deleted_at',
          )
          .eq('farm_id', _farmId)
          .order('name', ascending: true);
      if (!mounted) return;
      setState(() {
        _partners = rows
            .map((r) => PartnerModel.fromJson(r))
            .where((p) => !p.isDeleted)
            .toList();
      });
    } catch (e) {
      debugPrint('madjana: report partners load failed: $e');
      if (!mounted) return;
      setState(() => _wdError = _arabicError(e));
    }
  }

  /// التبويب 2 — يجلب سحوبات المزرعة عبر [partnerWithdrawalRepositoryProvider]
  /// ويصفّي بالتاريخ/الحالة/الشريك من العميل (المستودع لا يدعم نطاق تواريخ).
  Future<void> _loadWithdrawals() async {
    if (_farmId.isEmpty) {
      setState(() => _wdError = 'لا مدجنة فعّالة');
      return;
    }
    setState(() {
      _wdLoading = true;
      _wdError = null;
    });
    try {
      final repo = ref.read(partnerWithdrawalRepositoryProvider);
      final withdrawals = await repo.getWithdrawals(
        farmId: _farmId,
        partnerId: _wdPartnerFilter,
        status: _wdStatusFilter,
      );
      final wdById = <String, PartnerWithdrawal>{};
      for (final w in withdrawals) wdById[w.id] = w;
      final byPartner = <String, String>{};
      for (final p in _partners) {
        if (p.id != null) byPartner[p.id!] = p.name;
      }
      final rows = <_WdRow>[];
      for (final w in withdrawals) {
        final ra = w.requestedAt;
        if (_wdFrom != null && ra != null && ra.isBefore(_wdFrom!)) continue;
        if (_wdTo != null && ra != null && ra.isAfter(_wdTo!)) continue;
        rows.add(_WdRow(
          id: w.id,
          partnerId: w.partnerId,
          partnerName: byPartner[w.partnerId] ?? w.partnerId,
          amount: w.amount,
          currency: w.currency,
          status: w.status,
          requestedAt: w.requestedAt,
          paidAt: w.paidAt,
          reason: w.reason,
        ));
      }
      rows.sort((a, b) {
        final da = a.requestedAt ?? DateTime(1970);
        final db = b.requestedAt ?? DateTime(1970);
        return db.compareTo(da);
      });
      if (!mounted) return;
      setState(() {
        _wdRows = rows;
        _wdById = wdById;
        _wdLoading = false;
      });
    } catch (e) {
      debugPrint('madjana: report withdrawals load failed: $e');
      if (!mounted) return;
      setState(() { _wdError = _arabicError(e); _wdLoading = false; });
    }
  }

  /// التبويب 3 — ملخص الشركاء: يتم حساب المقادير من الجداول مباشرة (بدون RPC).
  Future<void> _loadPartnershipSummary() async {
    if (_farmId.isEmpty) {
      setState(() => _summaryError = 'لا مدجنة فعّالة');
      return;
    }
    setState(() {
      _summaryLoading = true;
      _summaryError = null;
    });
    try {
      final supabase = ref.read(supabaseClientProvider);
      final now = DateTime.now();
      final yearStart = DateTime(now.year);

      final distRows = await supabase
          .from('profit_distributions')
          .select('id, status, period_start, period_end')
          .eq('farm_id', _farmId);
      final distStatus = <String, String>{};
      final distPeriodStart = <String, DateTime?>{};
      for (final d in distRows) {
        final id = (d['id'] ?? '').toString();
        distStatus[id] = (d['status'] ?? '').toString();
        distPeriodStart[id] = _parseDate(d['period_start']);
      }

      final detailRows = await supabase
          .from('profit_distribution_details')
          .select('distribution_id, partner_id, profit_share')
          .eq('farm_id', _farmId);

      final netProfit = <String, double>{};
      for (final d in detailRows) {
        final distId = (d['distribution_id'] ?? '').toString();
        final partnerId = (d['partner_id'] ?? '').toString();
        final st = distStatus[distId] ?? '';
        if (st != 'approved' && st != 'paid') continue;
        final ps = distPeriodStart[distId];
        if (ps == null || ps.isBefore(yearStart)) continue;
        final share = _toDouble(d['profit_share']) ?? 0;
        netProfit.update(partnerId, (v) => v + share, ifAbsent: () => share);
      }

      final wdRows = await supabase
          .from('partner_withdrawals')
          .select('partner_id, amount, status')
          .eq('farm_id', _farmId);

      final pendingWd = <String, double>{};
      final paidWd = <String, double>{};
      for (final w in wdRows) {
        final partnerId = (w['partner_id'] ?? '').toString();
        final amount = _toDouble(w['amount']) ?? 0;
        final st = (w['status'] ?? '').toString();
        if (st == 'pending' || st == 'approved') {
          pendingWd.update(partnerId, (v) => v + amount, ifAbsent: () => amount);
        }
        if (st == 'paid') {
          paidWd.update(partnerId, (v) => v + amount, ifAbsent: () => amount);
        }
      }

      final byPartner = <String, String>{};
      for (final p in _partners) {
        if (p.id != null) byPartner[p.id!] = p.name;
      }
      final allPartnerIds = <String>{}
        ..addAll(netProfit.keys)
        ..addAll(pendingWd.keys)
        ..addAll(paidWd.keys);
      if (_summaryPartnerFilter != null && _summaryPartnerFilter!.isNotEmpty) {
        allPartnerIds.removeWhere((id) => id != _summaryPartnerFilter);
      }

      final rows = <_PartnerSummaryRow>[];
      for (final pid in allPartnerIds) {
        final np = netProfit[pid] ?? 0;
        final pe = pendingWd[pid] ?? 0;
        final pa = paidWd[pid] ?? 0;
        rows.add(_PartnerSummaryRow(
          partnerId: pid,
          partnerName: byPartner[pid] ?? pid,
          shareModel: _shareModelOf(pid),
          netProfit: np,
          pending: pe,
          paid: pa,
          available: np - pe - pa,
        ));
      }
      rows.sort((a, b) => b.partnerName.compareTo(a.partnerName));

      if (!mounted) return;
      setState(() {
        _summaryRows = rows;
        _summaryLoading = false;
      });
    } catch (e) {
      debugPrint('madjana: report partnership summary load failed: $e');
      if (!mounted) return;
      setState(() { _summaryError = _arabicError(e); _summaryLoading = false; });
    }
  }

  String? _shareModelOf(String partnerId) {
    final p = _partners.firstWhereOrNull((p) => p.id == partnerId);
    return p?.shareModel.name;
  }

  /// التبويب 4 — أداء الفترات وأداء الشركاء (للرسم البياني والجدولين).
  Future<void> _loadPerformance() async {
    if (_farmId.isEmpty) {
      setState(() => _perfError = 'لا مدجنة فعّالة');
      return;
    }
    setState(() {
      _perfLoading = true;
      _perfError = null;
    });
    try {
      final supabase = ref.read(supabaseClientProvider);

      final distRows = await supabase
          .from('profit_distributions')
          .select('id, net_profit, period_start, period_end, status')
          .eq('farm_id', _farmId)
          .order('period_start', ascending: false);
      final detailRows = await supabase
          .from('profit_distribution_details')
          .select('distribution_id, partner_id, profit_share')
          .eq('farm_id', _farmId);
      final wdRows = await supabase
          .from('partner_withdrawals')
          .select('partner_id, amount, status')
          .eq('farm_id', _farmId);

      final distDistributed = <String, double>{};
      final distPartnerCount = <String, int>{};
      for (final d in detailRows) {
        final distId = (d['distribution_id'] ?? '').toString();
        final partnerId = (d['partner_id'] ?? '').toString();
        distDistributed.update(distId, (v) => v + (_toDouble(d['profit_share']) ?? 0),
            ifAbsent: () => _toDouble(d['profit_share']) ?? 0);
        distPartnerCount.update(distId, (v) => v + 1, ifAbsent: () => 1);
      }

      final periodRows = <_PerfPeriodRow>[];
      final top4 = distRows.take(4).toList()..sort(
            (a, b) => (_parseDate(a['period_start']) ?? DateTime(1970))
                .compareTo(_parseDate(b['period_start']) ?? DateTime(1970)),
          );
      for (final d in top4) {
        final id = (d['id'] ?? '').toString();
        final ps = _parseDate(d['period_start']);
        final pe = _parseDate(d['period_end']);
        periodRows.add(_PerfPeriodRow(
          period: _periodLabel(ps, pe),
          periodStart: ps,
          netProfit: _toDouble(d['net_profit']) ?? 0,
          distributed: distDistributed[id] ?? 0,
          partnerCount: distPartnerCount[id] ?? 0,
        ));
      }

      final now = DateTime.now();
      final yearStart = DateTime(now.year);
      final netProfit = <String, double>{};
      final pendingWd = <String, double>{};
      final paidWd = <String, double>{};
      for (final d in detailRows) {
        final distId = (d['distribution_id'] ?? '').toString();
        final partnerId = (d['partner_id'] ?? '').toString();
        final dist = distRows.firstWhere(
          (x) => (x['id'] ?? '').toString() == distId,
          orElse: () => <String, dynamic>{},
        );
        if (dist.isEmpty) continue;
        final st = (dist['status'] ?? '').toString();
        if (st != 'approved' && st != 'paid') continue;
        final ps = _parseDate(dist['period_start']);
        if (ps == null || ps.isBefore(yearStart)) continue;
        netProfit.update(partnerId, (v) => v + (_toDouble(d['profit_share']) ?? 0),
            ifAbsent: () => _toDouble(d['profit_share']) ?? 0);
      }
      for (final w in wdRows) {
        final partnerId = (w['partner_id'] ?? '').toString();
        final amount = _toDouble(w['amount']) ?? 0;
        final st = (w['status'] ?? '').toString();
        if (st == 'pending' || st == 'approved') {
          pendingWd.update(partnerId, (v) => v + amount, ifAbsent: () => amount);
        }
        if (st == 'paid') {
          paidWd.update(partnerId, (v) => v + amount, ifAbsent: () => amount);
        }
      }
      final byPartner = <String, String>{};
      for (final p in _partners) {
        if (p.id != null) byPartner[p.id!] = p.name;
      }
      final allIds = <String>{}
        ..addAll(netProfit.keys)
        ..addAll(pendingWd.keys)
        ..addAll(paidWd.keys);
      final partnerRows = <_PerfPartnerRow>[];
      for (final pid in allIds) {
        final np = netProfit[pid] ?? 0;
        final pe = pendingWd[pid] ?? 0;
        final pa = paidWd[pid] ?? 0;
        partnerRows.add(_PerfPartnerRow(
          partnerName: byPartner[pid] ?? pid,
          netProfit: np,
          totalWithdrawals: pe + pa,
          available: np - pe - pa,
        ));
      }
      partnerRows.sort((a, b) => b.available.compareTo(a.available));

      if (!mounted) return;
      setState(() {
        _perfPeriodRows = periodRows;
        _perfPartnerRows = partnerRows;
        _perfLoading = false;
      });
    } catch (e) {
      debugPrint('madjana: report performance load failed: $e');
      if (!mounted) return;
      setState(() { _perfError = _arabicError(e); _perfLoading = false; });
    }
  }

  DateTime? _parseDate(dynamic v) =>
      v == null ? null : DateTime.tryParse(v.toString());

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
  List<_DistRow> get _filteredDistRows {
    return _distRows.where((r) {
      if (_distFrom != null && r.periodStart != null &&
          r.periodStart!.isBefore(_distFrom!)) return false;
      if (_distTo != null && r.periodEnd != null &&
          r.periodEnd!.isAfter(_distTo!)) return false;
      if (_distStatusFilter != null && r.status != _distStatusFilter) return false;
      return true;
    }).toList();
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isFrom) _distFrom = picked;
      if (!isFrom) _distTo = picked;
    });
  }

  Future<void> _pickWdDate({required bool isFrom}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isFrom) _wdFrom = picked;
      if (!isFrom) _wdTo = picked;
    });
  }

  Future<void> _exportDistCSV() async {
    final rows = _filteredDistRows;
    final buffer = StringBuffer();
    buffer.writeln(
      'الفترة,إجمالي الإيراد,المصروف,صافي الربح,الموزع,الحالة,عدد الشركاء',
    );
    for (final r in rows) {
      buffer.writeln(
        '"${r.period}",${_num(r.totalRevenue)},${_num(r.totalExpenses)},'
        '${_num(r.netProfit)},"${r.distributor}","${r.status.label}",${r.partnerCount}',
      );
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تم نسخ تقرير التوزيعات إلى الحافظة (CSV)'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _openDistDetails(_DistRow row) async {
    final ok = await _confirm(
      'عرض تفاصيل التوزيع',
      'سيتم فتح شاشة التوزيع (W7.3) لعرض/تصفية حسب الفترة المختارة.\n'
      'الفترة: ${row.period} · الحالة: ${row.status.label}',
    );
    if (ok != true) return;
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ProfitDistributionScreen(),
      ),
    );
  }

  String _arabicError(Object e) {
    if (e is SyncFailure) {
      switch (e.code) {
        case 'AUTHORIZATION_DENIED':
          return 'لا تملك صلاحية عرض هذه البيانات.';
        case 'INVALID_PERIOD':
          return 'الفترة المختارة غير صالحة.';
        case 'FARM_NOT_FOUND':
          return 'المدجنة غير موجودة.';
        default:
          return e.message;
      }
    }
    return e.toString().replaceFirst('Exception: ', '');
  }

  String _fmtDate(DateTime? d) =>
      d == null ? '' : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// التبويب 2 — تسمية حالة السحب للعرض (النصوص في الموديل عربية أصلاً).
  String _fmtWdStatus(PartnerWithdrawalStatus s) => s.label;

  /// التبويب 2 — تصدير الصفوف المُصفّاة إلى CSV في الحافظة (نظامي، بدون حزم خارجية).
  Future<void> _exportWdCsv() async {
    if (_wdRows.isEmpty) return;
    final buffer = StringBuffer();
    buffer.writeln('id,partner_name,amount,currency,status,requested_at,paid_at,reason');
    for (final r in _wdRows) {
      buffer.writeln(
        '${r.id},"${r.partnerName}",${_num(r.amount)},"${r.currency}",'
        '"${_fmtWdStatus(r.status)}",${_fmtDate(r.requestedAt)},${_fmtDate(r.paidAt)},'
        '"${r.reason ?? ''}"',
      );
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تم نسخ تقرير السحوبات إلى الحافظة (CSV)'),
        backgroundColor: Colors.green,
      ),
    );
  }

  /// التبويب 2 — فتح تفاصيل السحب بعد تأكيد المستخدم.
  Future<void> _openWdDetails(_WdRow row) async {
    final w = _wdById[row.id];
    if (w == null) return;
    final ok = await _confirm(
      'عرض تفاصيل السحب',
      'سيتم فتح شاشة تفاصيل السحب (W7.6).\n'
      'الشريك: ${_partners.firstWhereOrNull((p) => p.id == w.partnerId)?.name ?? w.partnerId} · المبلغ: ${_num(w.amount)} ${w.currency}',
    );
    if (ok != true) return;
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WithdrawalDetailsScreen(withdrawal: w),
      ),
    );
  }

  Future<bool?> _confirm(String title, String content) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('متابعة'),
          ),
        ],
      ),
    );
  }

  String _periodLabel(DateTime? start, DateTime? end) {
    if (start == null || end == null) return '—';
    return '${_formatDate(start)} → ${_formatDate(end)}';
  }

  String _nameOfUser(String uid) {
    if (uid.isEmpty) return '—';
    return uid.length > 12 ? '${uid.substring(0, 8)}…' : uid;
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

  String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('تقارير الشراكة'),
        bottom: TabBar(
          controller: _tabController,
          onTap: (i) => setState(() => _selectedTab = i),
          tabs: const [
            Tab(text: 'التوزيعات', icon: Icon(Icons.attach_money_rounded)),
            Tab(text: 'السحوبات', icon: Icon(Icons.payments)),
            Tab(text: 'ملخص الشركاء', icon: Icon(Icons.people_rounded)),
            Tab(text: 'الأداء', icon: Icon(Icons.analytics_rounded)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDistributionsTab(theme),
          _buildTab2(theme),
          _buildTab3(theme),
          _buildTab4(theme),
        ],
      ),
    );
  }
  Widget _buildDistributionsTab(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _distLoading ? null : _exportDistCSV,
                      icon: _distLoading
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.file_download_rounded, size: 18),
                      label: const Text('تصدير CSV'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: OutlinedButton.icon(
                      onPressed: _distLoading ? null : _loadDistributions,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('تحديث'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.event_rounded, size: 16),
                    label: Text(
                      'من: ${_distFrom == null ? '—' : _formatDate(_distFrom!)}',
                    ),
                    onPressed: _distLoading ? null : () => _pickDate(isFrom: true),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.event_rounded, size: 16),
                    label: Text(
                      'إلى: ${_distTo == null ? '—' : _formatDate(_distTo!)}',
                    ),
                    onPressed: _distLoading ? null : () => _pickDate(isFrom: false),
                  ),
                  DropdownButton<ProfitDistributionStatus?>(
                    value: _distStatusFilter,
                    isDense: true,
                    underline: const SizedBox(),
                    items: [
                      const DropdownMenuItem<ProfitDistributionStatus?>(
                        value: null,
                        child: Text('الحالة: الكل'),
                      ),
                      for (final s in ProfitDistributionStatus.values)
                        DropdownMenuItem<ProfitDistributionStatus?>(
                          value: s,
                          child: Text('الحالة: ${s.label}'),
                        ),
                    ],
                    onChanged: _distLoading
                        ? null
                        : (v) => setState(() => _distStatusFilter = v),
                  ),
                  if (_distError != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer
                              .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _distError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _distLoading
              ? const Center(child: CircularProgressIndicator())
              : _filteredDistRows.isEmpty
                  ? Center(
                      child: Text(
                        'لا توجد توزيعات تتطابق مع الفلاتر',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    )
                  : Scrollbar(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('الفترة')),
                            DataColumn(label: Text('إجمالي الإيراد')),
                            DataColumn(label: Text('المصروف')),
                            DataColumn(label: Text('صافي الربح')),
                            DataColumn(label: Text('الموزع')),
                            DataColumn(label: Text('الحالة')),
                            DataColumn(label: Text('عدد الشركاء')),
                            DataColumn(label: Text('إجراء')),
                          ],
                          rows: _filteredDistRows
                              .map((r) => DataRow(cells: [
                                    DataCell(Text(r.period)),
                                    DataCell(Text(_num(r.totalRevenue))),
                                    DataCell(Text(_num(r.totalExpenses))),
                                    DataCell(Text(_num(r.netProfit))),
                                    DataCell(Text(r.distributor)),
                                    DataCell(_StatusChipDist(status: r.status)),
                                    DataCell(Text('${r.partnerCount}')),
                                    DataCell(
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          OutlinedButton.icon(
                                            onPressed: () => _openDistDetails(r),
                                            icon: const Icon(
                                              Icons.info_outline,
                                              size: 16,
                                            ),
                                            label: const Text('تفاصيل'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ]))
                              .toList(),
                        ),
                      ),
                    ),
        ),
      ],
    );
  }
  Widget _buildTab2(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _wdLoading ? null : _exportWdCsv,
                      icon: _wdLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.file_download_rounded, size: 18),
                      label: const Text('تصدير CSV'),
                    ),
                  ),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _wdLoading ? null : _loadWithdrawals,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('تحديث'),
                    ),
                  ),
                  Expanded(
                    child: DropdownButton<String?>(
                      value: _wdPartnerFilter,
                      hint: const Text('الشريك: الكل'),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('الشريك: الكل'),
                        ),
                        for (final p in _partners)
                          DropdownMenuItem<String?>(
                            value: p.id,
                            child: Text(p.name),
                          ),
                      ],
                      onChanged: _wdLoading
                          ? null
                          : (v) => setState(() => _wdPartnerFilter = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.event_rounded, size: 16),
                    label: Text(
                      'من: ${_wdFrom == null ? '—' : _formatDate(_wdFrom!)}',
                    ),
                    onPressed: _wdLoading ? null : () => _pickWdDate(isFrom: true),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.event_rounded, size: 16),
                    label: Text(
                      'إلى: ${_wdTo == null ? '—' : _formatDate(_wdTo!)}',
                    ),
                    onPressed: _wdLoading ? null : () => _pickWdDate(isFrom: false),
                  ),
                  DropdownButton<PartnerWithdrawalStatus?>(
                    value: _wdStatusFilter,
                    hint: const Text('الحالة: الكل'),
                    items: [
                      const DropdownMenuItem<PartnerWithdrawalStatus?>(
                        value: null,
                        child: Text('الحالة: الكل'),
                      ),
                      for (final s in PartnerWithdrawalStatus.values)
                        DropdownMenuItem<PartnerWithdrawalStatus?>(
                          value: s,
                          child: Text('الحالة: ${s.label}'),
                        ),
                    ],
                    onChanged: _wdLoading
                        ? null
                        : (v) => setState(() => _wdStatusFilter = v),
                  ),
                  if (_wdError != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(_wdError!, style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _wdLoading
              ? const Center(child: CircularProgressIndicator())
              : _wdRows.isEmpty
                  ? const Center(child: Text('لا توجد سحوبات'))
                  : Scrollbar(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('الشريك')),
                            DataColumn(label: Text('المبلغ')),
                            DataColumn(label: Text('العملة')),
                            DataColumn(label: Text('الحالة')),
                            DataColumn(label: Text('تاريخ الطلب')),
                            DataColumn(label: Text('تاريخ الصرف')),
                            DataColumn(label: Text('السبب')),
                            DataColumn(label: Text('الإجراء')),
                          ],
                          rows: _wdRows.map((r) => _buildWdRow(r)).toList(),
                        ),
                      ),
                    ),
        ),
      ],
    );
  }

  DataRow _buildWdRow(_WdRow r) {
    return DataRow(
      cells: [
        DataCell(Text(r.partnerName)),
        DataCell(Text(_num(r.amount))),
        DataCell(Text(r.currency)),
        DataCell(Text(_fmtWdStatus(r.status))),
        DataCell(Text(_fmtDate(r.requestedAt))),
        DataCell(Text(_fmtDate(r.paidAt))),
        DataCell(Text(r.reason ?? '—')),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: _wdLoading ? null : () => _openWdDetails(r),
                icon: const Icon(Icons.info_outline, size: 16),
                label: const Text('تفاصيل'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _exportSummaryCsv() async {
    if (_summaryRows.isEmpty) return;
    final buffer = StringBuffer();
    buffer.writeln(
      'الشريك,نموذج المشاركة,صافي الربح,سحوبات معلقة,سحوبات مسددة,المتاح للصرف',
    );
    for (final r in _summaryRows) {
      buffer.writeln(
        '"${r.partnerName}","${r.shareModel ?? ''}",'
        '${_num(r.netProfit)},${_num(r.pending)},${_num(r.paid)},${_num(r.available)}',
      );
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تم نسخ تقرير ملخص الشركاء إلى الحافظة (CSV)'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Widget _buildTab3(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _summaryLoading ? null : _exportSummaryCsv,
                      icon: const Icon(Icons.file_download_rounded, size: 18),
                      label: const Text('تصدير CSV'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _summaryLoading ? null : _loadPartnershipSummary,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('تحديث'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<String?>(
                      value: _summaryPartnerFilter,
                      hint: const Text('الشريك: الكل'),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('الشريك: الكل'),
                        ),
                        for (final p in _partners)
                          DropdownMenuItem<String?>(
                            value: p.id,
                            child: Text(p.name),
                          ),
                      ],
                      onChanged: _summaryLoading
                          ? null
                          : (v) => setState(() => _summaryPartnerFilter = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_summaryError != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_summaryError!,
                      style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
        Expanded(
          child: _summaryLoading
              ? const Center(child: CircularProgressIndicator())
              : _summaryRows.isEmpty
                  ? const Center(child: Text('لا توجد بيانات'))
                  : Scrollbar(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('الشريك')),
                            DataColumn(label: Text('نموذج المشاركة')),
                            DataColumn(label: Text('صافي الربح')),
                            DataColumn(label: Text('سحوبات معلقة')),
                            DataColumn(label: Text('سحوبات مسددة')),
                            DataColumn(label: Text('المتاح للصرف')),
                          ],
                          rows: _summaryRows.map((r) => _buildSummaryRow(r)).toList(),
                        ),
                      ),
                    ),
        ),
      ],
    );
  }

  DataRow _buildSummaryRow(_PartnerSummaryRow r) {
    return DataRow(
      cells: [
        DataCell(Text(r.partnerName)),
        DataCell(Text(r.shareModel ?? '—')),
        DataCell(Text(_num(r.netProfit))),
        DataCell(Text(_num(r.pending))),
        DataCell(Text(_num(r.paid))),
        DataCell(
          Text(_num(r.available),
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Future<void> _exportPerfCsv() async {
    if (_perfPeriodRows.isEmpty) return;
    final buffer = StringBuffer();
    buffer.writeln('الفترة,صافي الربح,الموزع,عدد الشركاء');
    for (final r in _perfPeriodRows) {
      buffer.writeln(
        '"${r.period}",${_num(r.netProfit)},${_num(r.distributed)},${r.partnerCount}',
      );
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تم نسخ تقرير الأداء إلى الحافظة (CSV)'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Widget _buildTab4(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _perfLoading ? null : _exportPerfCsv,
                      icon: const Icon(Icons.file_download_rounded, size: 18),
                      label: const Text('تصدير CSV'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _perfLoading ? null : _loadPerformance,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('تحديث'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_perfError != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_perfError!,
                      style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
                ),
                const SizedBox(height: 8),
              ],
              Text('صافي الربح حسب الفترة (آخر 4 فترات)',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              SizedBox(
                height: 220,
                child: SimpleBarChart(
                  values: _perfPeriodRows.map((e) => e.netProfit).toList(),
                  labels: _perfPeriodRows.map((e) => e.period).toList(),
                ),
              ),
              const SizedBox(height: 16),
              Text('تفاصيل الفترات', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Expanded(
                child: _perfPeriodRows.isEmpty
                    ? const Center(child: Text('لا توجد فترات'))
                    : Scrollbar(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: const [
                              DataColumn(label: Text('الفترة')),
                              DataColumn(label: Text('صافي الربح')),
                              DataColumn(label: Text('الموزع')),
                              DataColumn(label: Text('عدد الشركاء')),
                            ],
                            rows: _perfPeriodRows
                                .map((r) => _buildPerfPeriodRow(r))
                                .toList(),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 16),
              Text('أداء الشركاء (هذه السنة)', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Expanded(
                child: _perfPartnerRows.isEmpty
                    ? const Center(child: Text('لا توجد بيانات'))
                    : Scrollbar(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: const [
                              DataColumn(label: Text('الشريك')),
                              DataColumn(label: Text('صافي الربح')),
                              DataColumn(label: Text('إجمالي السحوبات')),
                              DataColumn(label: Text('المتاح للصرف')),
                            ],
                            rows: _perfPartnerRows
                                .map((r) => _buildPerfPartnerRow(r))
                                .toList(),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  DataRow _buildPerfPeriodRow(_PerfPeriodRow r) {
    return DataRow(
      cells: [
        DataCell(Text(r.period)),
        DataCell(Text(_num(r.netProfit))),
        DataCell(Text(_num(r.distributed))),
        DataCell(Text('${r.partnerCount}')),
      ],
    );
  }

  DataRow _buildPerfPartnerRow(_PerfPartnerRow r) {
    return DataRow(
      cells: [
        DataCell(Text(r.partnerName)),
        DataCell(Text(_num(r.netProfit))),
        DataCell(Text(_num(r.totalWithdrawals))),
        DataCell(
          Text(_num(r.available),
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _buildPlaceholderTab(String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.construction_rounded,
              size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(subtitle,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
              )),
        ],
      ),
    );
  }
}

class _DistRow {
  final String id;
  final String period;
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final double totalRevenue;
  final double totalExpenses;
  final double netProfit;
  final String distributor;
  final ProfitDistributionStatus status;
  final int partnerCount;

  _DistRow({
    required this.id,
    required this.period,
    this.periodStart,
    this.periodEnd,
    required this.totalRevenue,
    required this.totalExpenses,
    required this.netProfit,
    required this.distributor,
    required this.status,
    required this.partnerCount,
  });
}

class _StatusChipDist extends StatelessWidget {
  final ProfitDistributionStatus status;

  const _StatusChipDist({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      ProfitDistributionStatus.draft => Colors.grey,
      ProfitDistributionStatus.calculated => Colors.blue,
      ProfitDistributionStatus.approved => Colors.green,
      ProfitDistributionStatus.distributed => Colors.indigo,
      ProfitDistributionStatus.cancelled => Colors.red,
    };
    return Chip(
      label: Text(status.label),
      visualDensity: VisualDensity.compact,
      backgroundColor: color.withValues(alpha: 0.12),
      side: BorderSide(color: color.withValues(alpha: 0.4)),
    );
  }
}

class _WdRow {
  final String id;
  final String partnerId;
  final String partnerName;
  final double amount;
  final String currency;
  final PartnerWithdrawalStatus status;
  final DateTime? requestedAt;
  final DateTime? paidAt;
  final String? reason;

  const _WdRow({
    required this.id,
    required this.partnerId,
    required this.partnerName,
    required this.amount,
    required this.currency,
    required this.status,
    this.requestedAt,
    this.paidAt,
    this.reason,
  });
}

class _PartnerSummaryRow {
  final String partnerId;
  final String partnerName;
  final String? shareModel;
  final double netProfit;
  final double pending;
  final double paid;
  final double available;

  const _PartnerSummaryRow({
    required this.partnerId,
    required this.partnerName,
    this.shareModel,
    required this.netProfit,
    required this.pending,
    required this.paid,
    required this.available,
  });
}

class _PerfPeriodRow {
  final String period;
  final DateTime? periodStart;
  final double netProfit;
  final double distributed;
  final int partnerCount;

  const _PerfPeriodRow({
    required this.period,
    this.periodStart,
    required this.netProfit,
    required this.distributed,
    required this.partnerCount,
  });
}

class _PerfPartnerRow {
  final String partnerName;
  final double netProfit;
  final double totalWithdrawals;
  final double available;

  const _PerfPartnerRow({
    required this.partnerName,
    required this.netProfit,
    required this.totalWithdrawals,
    required this.available,
  });
}