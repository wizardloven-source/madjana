import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../core/design_tokens.dart';
import '../../../core/providers.dart';
import '../../../core/shell_state.dart';
import '../../auth/providers/auth_provider.dart';

/// لوحة التحكم - نظرة عامة للمدير
///
/// - KPIs: إنتاج اليوم/الشهر، النفوق، القبض، المخزونات
/// - مخزون البيض الحالي وطلبات الموافقة المعلقة (قابلة للنقر)
/// - تنبيهات ذكية (علف منخفض، أصناف تحت الحد الأدنى)
/// - ملخص القطعان + أحدث العمليات + رسم بياني
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  List<EggProductionModel> _eggRecords = [];
  List<MortalityModel> _mortalityRecords = [];
  List<DispatchModel> _dispatches = [];
  List<FlockModel> _flocks = [];
  List<InventoryItemModel> _inventoryItems = [];
  List<FeedConsumptionModel> _consumptionWeek = [];
  List<OpeningBalanceModel> _openingBalances = [];
  double _outstanding = 0;
  double _collected = 0;
  double _feedStock = 0;
  int _pendingApprovals = 0;
  bool _loading = true;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final farmId = _farmId;
    final eggRepo = ref.read(eggProductionRepositoryProvider);
    final mortalityRepo = ref.read(mortalityRepositoryProvider);
    final feedRepo = ref.read(feedRepositoryProvider);
    final paymentRepo = ref.read(paymentRepositoryProvider);
    final dispatchRepo = ref.read(dispatchRepositoryProvider);

    // مزامنة البيانات أولاً: رفع المعلّق + سحب سجلات الأجهزة الأخرى
    try {
      final syncRepo = ref.read(syncRepositoryProvider);
      final pulled = await syncRepo.syncNow(farmId);
      if (pulled.uploadedCount > 0 || pulled.downloadedCount > 0 && mounted) {
        ref.read(dataRefreshTickProvider.notifier).state++;
      }
    } catch (_) {}

    final today = DateTime.now();
    final monthAgo = today.subtract(const Duration(days: 30));
    final weekAgoStart = DateTime(today.year, today.month, today.day)
        .subtract(const Duration(days: 6));

    try {
      final results = await Future.wait([
        eggRepo.getAllRecords(farmId: farmId, fromDate: monthAgo, toDate: today),
        mortalityRepo.getAllRecords(
            farmId: farmId, fromDate: monthAgo, toDate: today),
        eggRepo.getAllRecords(farmId: farmId),
        dispatchRepo.getAll(farmId: farmId),
        paymentRepo.getTotalOutstanding(farmId: farmId),
        paymentRepo.getTotalCollected(
          farmId: farmId,
          fromDate: monthAgo,
          toDate: today,
        ),
        feedRepo.getCurrentFeedStock(farmId),
        ref.read(flockRepositoryProvider).getFlocks(farmId, includeEnded: true),
        ref.read(inventoryRepositoryProvider).getItems(farmId),
      ]);

      _eggRecords =
          results[0] as List<EggProductionModel>;
      _mortalityRecords = results[1] as List<MortalityModel>;
      final allEggs = results[2] as List<EggProductionModel>;
      _dispatches = results[3] as List<DispatchModel>;
      _outstanding = results[4] as double;
      _collected = results[5] as double;
      _feedStock = results[6] as double;
      _flocks = results[7] as List<FlockModel>;
      _inventoryItems = results[8] as List<InventoryItemModel>;

      // استهلاك العلف لآخر 7 أيام (للتنبؤ بالنفاد)
      _consumptionWeek = await feedRepo.getAllConsumption(
        farmId: farmId,
        fromDate: weekAgoStart,
        toDate: today,
      );

      // مخزون البيض الحالي = كل الإنتاج - كل التخريج
      _currentEggStock = allEggs.fold<int>(0, (s, e) => s + e.totalEggs) -
          _dispatches.fold<int>(0, (s, d) => s + d.totalEggs);
      if (_currentEggStock < 0) _currentEggStock = 0;

      // الأرصدة الافتتاحية للقطعان القديمة
      try {
        _openingBalances =
            await ref.read(openingBalanceRepositoryProvider).getForFarm(farmId);
        final openingNet = _openingBalances.fold<int>(
          0,
          (s, b) => s + b.eggsProduced - b.eggsDispatched,
        );
        _currentEggStock += openingNet;
        if (_currentEggStock < 0) _currentEggStock = 0;
      } catch (_) {
        _openingBalances = [];
      }

      // طلبات الموافقة المعلقة من السحابة
      try {
        final rows = await ref
            .read(supabaseClientProvider)
            .from('dispatch_requests')
            .select('id')
            .eq('status', 'pending');
        _pendingApprovals = (rows as List).length;
        ref.read(pendingApprovalsProvider.notifier).state =
            _pendingApprovals;
      } catch (_) {
        _pendingApprovals = 0;
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() => _loading = false);
  }

  int _currentEggStock = 0;

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final now = DateTime.now();
    final todayEggs = _eggRecords
        .where((e) =>
            e.date.year == now.year &&
            e.date.month == now.month &&
            e.date.day == now.day)
        .fold<int>(0, (sum, e) => sum + e.totalEggs);

    final totalEggs =
        _eggRecords.fold<int>(0, (sum, e) => sum + e.totalEggs);
    final totalMortality =
        _mortalityRecords.fold<int>(0, (sum, m) => sum + m.count);

    final activeFlocks =
        _flocks.where((f) => f.status == FlockStatus.active).toList();
    final totalBirds =
        activeFlocks.fold<int>(0, (sum, f) => sum + f.currentCount);

    // ---- المؤشرات التحليلية (معدل الإنتاج / النفوق / العلف) ----
    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 6));
    bool inLast7(DateTime d) =>
        !d.isBefore(weekStart) && !d.isAfter(now);

    final eggs7 = _eggRecords
        .where((e) => inLast7(e.date))
        .fold<int>(0, (s, e) => s + e.totalEggs);
    final deaths7 = _mortalityRecords
        .where((m) => inLast7(m.date))
        .fold<int>(0, (s, m) => s + m.count);
    final consumed7 = _consumptionWeek.fold<double>(
        0, (s, r) => s + r.quantityKg);

    final prodRateToday = FarmAnalytics.productionRate(
        eggs: todayEggs, birdCount: totalBirds);
    final prodRateWeek = FarmAnalytics.avgProductionRate(
        totalEggs: eggs7, birdCount: totalBirds, days: 7);
    final mortRateWeek = FarmAnalytics.dailyMortalityRate(
        totalDeaths: deaths7, birdCount: totalBirds, days: 7);
    final mortLevel = FarmAnalytics.mortalityLevel(mortRateWeek);
    final feedDaysLeft = FarmAnalytics.feedDaysLeft(
      stockKg: _feedStock,
      avgDailyConsumptionKg:
          consumed7 > 0 ? consumed7 / 7 : 0,
    );
    final feedLevel = FarmAnalytics.feedLevel(feedDaysLeft);

    // تنبيهات ذكية (مصنّفة حسب الخطورة)
    final alerts = <_Alert>[];
    if (_feedStock < 500) {
      alerts.add(_Alert(
        icon: Icons.grass,
        text:
            'مخزون العلف منخفض (${Formatters.formatNumber(_feedStock.toInt())} كغ)',
        severity: _AlertSeverity.warning,
      ));
    }
    if (feedLevel == 'danger' && feedDaysLeft != null) {
      alerts.add(_Alert(
        icon: Icons.timer_off,
        text:
            'العلف ينفد خلال ${feedDaysLeft.toStringAsFixed(1)} يوم فقط! اطلب توريداً الآن',
        severity: _AlertSeverity.danger,
      ));
    } else if (feedLevel == 'warning' && feedDaysLeft != null) {
      alerts.add(_Alert(
        icon: Icons.schedule,
        text:
            'العلف يكفي ~${feedDaysLeft.toStringAsFixed(0)} يوم — خطط للتوريد',
        severity: _AlertSeverity.warning,
      ));
    }
    if (mortLevel == 'danger') {
      alerts.add(_Alert(
        icon: Icons.warning,
        text:
            'معدل النفوق اليومي خطر (${mortRateWeek.toStringAsFixed(2)}%) — افحص المدجنة فوراً',
        severity: _AlertSeverity.danger,
      ));
    } else if (mortLevel == 'warning') {
      alerts.add(_Alert(
        icon: Icons.monitor_heart_outlined,
        text:
            'معدل النفوق مرتفع (${mortRateWeek.toStringAsFixed(2)}% يومياً) — راقب عن قرب',
        severity: _AlertSeverity.warning,
      ));
    }
    for (final item in _inventoryItems) {
      if (item.quantity <= item.lowStockThreshold) {
        alerts.add(_Alert(
          icon: Icons.inventory_2,
          text:
              '${item.name}: ${Formatters.formatNumber(item.quantity)} — تحت الحد الأدنى',
          severity: _AlertSeverity.danger,
        ));
      }
    }

    // أحدث العمليات
    final recent = <_Activity>[
      for (final e in _eggRecords.take(30))
        _Activity(
          icon: Icons.egg_alt,
          color: AppStatusColors.info(context),
          title:
              'إنتاج بيض: ${Formatters.formatNumber(e.totalEggs)} بيضة${e.sectionNo != null ? ' — عنبر ${e.sectionNo}' : ''}',
          date: e.date,
        ),
      for (final m in _mortalityRecords.take(20))
        _Activity(
          icon: Icons.heart_broken,
          color: AppStatusColors.danger(context),
          title: 'نفوق: ${m.count} طائر',
          date: m.date,
        ),
      for (final d in _dispatches.take(20))
        _Activity(
          icon: Icons.local_shipping,
          color: AppStatusColors.success(context),
          title: 'تخريج: ${Formatters.formatNumber(d.totalEggs)} بيضة',
          date: d.date,
        ),
    ]..sort((a, b) => b.date.compareTo(a.date));
    final recentVisible = recent.take(8).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // بطاقات KPIs — الأولوية للمؤشرات الصحية (إنتاج/نفوق/علف)
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              _KpiCard(
                title: 'إنتاج اليوم (بيضة)',
                value: Formatters.formatNumber(todayEggs),
                icon: Icons.egg_alt,
                color: AppStatusColors.success(context),
              ),
              _KpiCard(
                title: 'معدل الإنتاج اليوم',
                value:
                    '${prodRateToday.toStringAsFixed(1)}%',
                icon: Icons.trending_up,
                color: prodRateToday >= 80
                    ? AppStatusColors.success(context)
                    : (prodRateToday >= 60
                        ? AppStatusColors.warning(context)
                        : AppStatusColors.danger(context)),
              ),
              _KpiCard(
                title: 'النفوق اليومي (متوسط أسبوع)',
                value:
                    '${mortRateWeek.toStringAsFixed(2)}%',
                icon: Icons.monitor_heart,
                color: mortLevel == 'danger'
                    ? AppStatusColors.danger(context)
                    : (mortLevel == 'warning'
                        ? AppStatusColors.warning(context)
                        : AppStatusColors.success(context)),
              ),
              _KpiCard(
                title: feedDaysLeft == null
                    ? 'تنبؤ العلف'
                    : 'العلف يكفي ~${feedDaysLeft.toStringAsFixed(0)} يوم',
                value: consumed7 > 0
                    ? '${Formatters.formatNumber(consumed7.toInt())} كغ/أسبوع'
                    : 'لا بيانات استهلاك',
                icon: Icons.grass,
                color: feedLevel == 'danger'
                    ? AppStatusColors.danger(context)
                    : (feedLevel == 'warning'
                        ? AppStatusColors.warning(context)
                        : AppStatusColors.info(context)),
              ),
              _KpiCard(
                title: 'إنتاج آخر 30 يوم',
                value: Formatters.formatNumber(totalEggs),
                icon: Icons.production_quantity_limits,
                color: AppStatusColors.info(context),
              ),
              _KpiCard(
                title: 'نفوق آخر 30 يوم',
                value: Formatters.formatNumber(totalMortality),
                icon: Icons.heart_broken,
                color: AppStatusColors.warning(context),
              ),
              _KpiCard(
                title: 'المقبوضات (30 يوم)',
                value: Formatters.formatCurrency(_collected),
                icon: Icons.payments,
                color: AppStatusColors.success(context),
              ),
              _KpiCard(
                title: 'المبالغ المستحقة',
                value: Formatters.formatCurrency(_outstanding),
                icon: Icons.pending_actions,
                color: AppStatusColors.warning(context),
              ),
              _KpiCard(
                title: 'مخزون العلف (كغ)',
                value: Formatters.formatNumber(_feedStock.toInt()),
                icon: Icons.inventory_2,
                color: AppStatusColors.info(context),
              ),
              _KpiCard(
                title: 'مخزون البيض الحالي',
                value: Formatters.formatNumber(_currentEggStock),
                icon: Icons.egg,
                color: AppStatusColors.primary(context),
              ),
              _ActionCard(
                title: 'طلبات موافقة معلقة',
                value: '$_pendingApprovals',
                subtitle: _pendingApprovals > 0
                    ? 'اضغط للمراجعة الآن'
                    : 'لا توجد طلبات',
                icon: Icons.approval,
                color: _pendingApprovals > 0
                    ? AppStatusColors.danger(context)
                    : AppStatusColors.success(context),
                onTap: () =>
                    ref.read(shellTabProvider.notifier).state = 6,
              ),
              _KpiCard(
                title: 'متوسط المعدل (7 أيام)',
                value:
                    '${prodRateWeek.toStringAsFixed(1)}%',
                icon: Icons.percent,
                color: prodRateWeek >= 80
                    ? AppStatusColors.success(context)
                    : (prodRateWeek >= 60
                        ? AppStatusColors.warning(context)
                        : AppStatusColors.danger(context)),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // تنبيهات + ملخص القطعان
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.notification_important,
                                color: AppStatusColors.warning(context)),
                            const SizedBox(width: 8),
                            const Text('تحتاج انتباهك',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (alerts.isEmpty)
                          Row(
                            children: [
                              Icon(Icons.check_circle,
                                  size: 18,
                                  color: AppStatusColors.success(context)),
                              const SizedBox(width: 6),
                              Text('كل شيء تحت السيطرة ✓',
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant)),
                            ],
                          )
                        else
                          for (final alert in alerts.take(5))
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Icon(
                                    alert.icon,
                                    size: 18,
                                    color: _alertColor(context, alert.severity),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Flexible(child: Text(alert.text)),
                                        const SizedBox(width: 6),
                                        _SeverityChip(
                                            severity: alert.severity),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.pets,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 8),
                            const Text('القطعان النشطة',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text('$totalBirds طائر في ${activeFlocks.length} مدجنة',
                            style: const TextStyle(fontSize: 16)),
                        const SizedBox(height: 8),
                        ...activeFlocks.map((f) => Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 3),
                              child: Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: f.sectionsCount > 1
                                          ? Theme.of(context)
                                              .colorScheme
                                              .secondary
                                          : Theme.of(context)
                                              .colorScheme
                                              .outline,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '${f.breed} — ${f.currentCount} طائر (${f.sectionsCount > 1 ? '${f.sectionsCount} عنابر' : 'عنبر واحد'})',
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            )),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // الأرصدة الافتتاحية للقطعان القديمة
          if (_openingBalances.isNotEmpty) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.savings_outlined,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        const Text(
                          'أرصدة القطعان القديمة (أُدخلت عند التجهيز)',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () =>
                              ref.read(shellTabProvider.notifier).state = 1,
                          icon: const Icon(Icons.chevron_left),
                          label: const Text('إدارة القطعان'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      children: _openingBalances.map((b) {
                        final flock = _flocks
                            .where((f) => f.id == b.flockId)
                            .toList();
                        final name =
                            flock.isNotEmpty ? flock.first.breed : 'قطيع';
                        return _OpeningBalanceChip(
                          flockName: name,
                          balance: b,
                          currency: 'ل.س',
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

          // رسم بياني + أحدث العمليات
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.bar_chart,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 8),
                            const Text(
                              'الإنتاج اليومي - آخر 30 يوم',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (_eggRecords.isNotEmpty) ...[
                          Row(
                            children: [
                              _ChartStat(
                                label: 'متوسط اليوم',
                                value: Formatters.formatNumber(todayEggs),
                              ),
                              const SizedBox(width: 20),
                              _ChartStat(
                                label: 'متوسط 30 يوم',
                                value:
                                    (totalEggs / _eggRecords.length).toStringAsFixed(0),
                              ),
                              const SizedBox(width: 20),
                              _ChartStat(
                                label: 'معدل الإنتاج',
                                value: '${prodRateToday.toStringAsFixed(1)}%',
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                        ],
                        SizedBox(
                          height: 260,
                          child: _EggChart(records: _eggRecords),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.history,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 8),
                            const Text('أحدث العمليات',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (recentVisible.isEmpty)
                          Text('لا توجد عمليات بعد',
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant))
                        else
                          ...recentVisible.map((a) => Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 5),
                                child: Row(
                                  children: [
                                    Icon(a.icon, size: 17, color: a.color),
                                    const SizedBox(width: 8),
                                    Expanded(
                                        child: Text(a.title,
                                            style: const TextStyle(
                                                fontSize: 13))),
                                    Text(
                                      '${a.date.day}/${a.date.month}',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant),
                                    ),
                                  ],
                                ),
                              )),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Alert {
  final IconData icon;
  final String text;

  // مستوى الخطورة: عاجل (danger) / متابعة (warning) / معلومات (info)
  final _AlertSeverity severity;

  const _Alert({
    required this.icon,
    required this.text,
    this.severity = _AlertSeverity.info,
  });
}

enum _AlertSeverity { danger, warning, info }

Color _alertColor(BuildContext context, _AlertSeverity severity) {
  switch (severity) {
    case _AlertSeverity.danger:
      return AppStatusColors.danger(context);
    case _AlertSeverity.warning:
      return AppStatusColors.warning(context);
    case _AlertSeverity.info:
      return AppStatusColors.info(context);
  }
}

String _severityLabel(_AlertSeverity severity) {
  switch (severity) {
    case _AlertSeverity.danger:
      return 'عاجل';
    case _AlertSeverity.warning:
      return 'متابعة';
    case _AlertSeverity.info:
      return 'معلومات';
  }
}

class _SeverityChip extends StatelessWidget {
  final _AlertSeverity severity;

  const _SeverityChip({required this.severity});

  @override
  Widget build(BuildContext context) {
    final color = _alertColor(context, severity);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _severityLabel(severity),
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}

class _Activity {
  final IconData icon;
  final Color color;
  final String title;
  final DateTime date;

  const _Activity({
    required this.icon,
    required this.color,
    required this.title,
    required this.date,
  });
}

class _KpiCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _KpiCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 32),
              const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// بطاقة قابلة للنقر للانتقال السريع لشاشة أخرى
class _ActionCard extends StatelessWidget {
  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Icon(icon, color: color, size: 32),
                    if (value != '0')
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          value,
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 14,
                        color: value != '0'
                            ? color
                            : Theme.of(context).hintColor)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// مؤشر سياقي صغير ضمن مخطط الإنتاج
class _ChartStat extends StatelessWidget {
  final String label;
  final String value;

  const _ChartStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

/// رسم بياني أعمدة للإنتاج اليومي
class _EggChart extends StatelessWidget {
  final List<EggProductionModel> records;

  const _EggChart({required this.records});

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return const Center(child: Text('لا توجد بيانات'));
    }

    final chartData = records.reversed.toList();

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: (chartData.map((e) => e.totalEggs.toDouble()).reduce(
                    (a, b) => a > b ? a : b) *
                1.2)
            .toDouble(),
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => Theme.of(context).colorScheme.inverseSurface,
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final record = chartData[groupIndex];
              return BarTooltipItem(
                '${record.date.day}/${record.date.month}\n'
                '${Formatters.formatNumber(record.totalEggs)} بيضة',
                TextStyle(
                    color: Theme.of(context).colorScheme.onInverseSurface,
                    fontSize: 12),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index < 0 || index >= chartData.length) {
                  return const SizedBox.shrink();
                }
                final d = chartData[index].date;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${d.day}/${d.month}',
                    style: const TextStyle(fontSize: 10),
                  ),
                );
              },
            ),
          ),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 44),
          ),
          rightTitles: const AxisTitles(),
          topTitles: const AxisTitles(),
        ),
        borderData: FlBorderData(show: false),
        barGroups: [
          for (var i = 0; i < chartData.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: chartData[i].totalEggs.toDouble(),
                  color: AppStatusColors.primary(context),
                  width: 14,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// شريحة عرض أرصدة قطيع قديم
class _OpeningBalanceChip extends StatelessWidget {
  final String flockName;
  final OpeningBalanceModel balance;
  final String currency;
  const _OpeningBalanceChip({
    required this.flockName,
    required this.balance,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final entries = <(IconData, String, String)>[
      (Icons.egg_alt, 'إنتاج', Formatters.formatNumber(balance.eggsProduced)),
      (Icons.local_shipping, 'تخريج',
          Formatters.formatNumber(balance.eggsDispatched)),
      (Icons.grass, 'علف',
          '${Formatters.formatNumber(balance.feedConsumedKg.toInt())} كغ'),
      (Icons.heart_broken, 'نفوق',
          Formatters.formatNumber(balance.mortalityCount)),
      (Icons.payments, 'مدفوعات',
          Formatters.formatCurrency(balance.totalPayments)),
      (Icons.savings, 'إيرادات',
          Formatters.formatCurrency(balance.totalRevenues)),
    ];
    return Container(
      width: 240,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(flockName,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final (icon, label, value) in entries)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(icon,
                      size: 14,
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text('$label: ', style: const TextStyle(fontSize: 12)),
                  Text(value,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
