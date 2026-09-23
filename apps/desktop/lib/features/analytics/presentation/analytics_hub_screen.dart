import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/analytics_providers.dart';
import '../../auth/providers/auth_provider.dart';

/// ═══════════════════════════════════════════════════════════════
/// شاشة مركز التحليلات — Phase 1: Operational Intelligence
///
/// تبويبات: إنتاج | نفوق | علف | قطعان | عملاء | موردون | تكلفة | ربحية
/// ═══════════════════════════════════════════════════════════════
class AnalyticsHubScreen extends ConsumerStatefulWidget {
  const AnalyticsHubScreen({super.key});

  @override
  ConsumerState<AnalyticsHubScreen> createState() => _AnalyticsHubScreenState();
}

class _AnalyticsHubScreenState extends ConsumerState<AnalyticsHubScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  DateRange _range = DateRange.last30Days();

  String get _farmId =>
      ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 8, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _pickRange(DateRange range) {
    setState(() => _range = range);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مركز التحليلات'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(100),
          child: Column(
            children: [
              _buildRangeSelector(),
              TabBar(
                controller: _tabController,
                isScrollable: true,
                tabs: const [
                  Tab(icon: Icon(Icons.egg_alt), text: 'الإنتاج'),
                  Tab(icon: Icon(Icons.heart_broken), text: 'النفوق'),
                  Tab(icon: Icon(Icons.grass), text: 'العلف'),
                  Tab(icon: Icon(Icons.pets), text: 'القطععان'),
                  Tab(icon: Icon(Icons.people), text: 'العملاء'),
                  Tab(icon: Icon(Icons.local_shipping), text: 'الموردون'),
                  Tab(icon: Icon(Icons.account_balance), text: 'التكلفة'),
                  Tab(icon: Icon(Icons.trending_up), text: 'الربحية'),
                ],
              ),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _ProductionTab(farmId: _farmId, range: _range),
          _MortalityTab(farmId: _farmId, range: _range),
          _FeedTab(farmId: _farmId, range: _range),
          _FlockTab(farmId: _farmId, range: _range),
          _CustomerTab(farmId: _farmId),
          _SupplierTab(farmId: _farmId, range: _range),
          _CostTab(farmId: _farmId, range: _range),
          _ProfitabilityTab(farmId: _farmId, range: _range),
        ],
      ),
    );
  }

  Widget _buildRangeSelector() {
    final ranges = [
      DateRange.today(),
      DateRange.yesterday(),
      DateRange.last7Days(),
      DateRange.last30Days(),
      DateRange.thisMonth(),
      DateRange.previousMonth(),
    ];

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: ranges.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final r = ranges[i];
          final selected = r.label == _range.label;
          return FilterChip(
            label: Text(r.label),
            selected: selected,
            onSelected: (_) => _pickRange(r),
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Production Tab
// ═══════════════════════════════════════════════════════════════

class _ProductionTab extends ConsumerWidget {
  final String farmId;
  final DateRange range;

  const _ProductionTab({required this.farmId, required this.range});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentAsync = ref.watch(productionKpiProvider(
        (farmId: farmId, range: range)));
    final prevRange = DateRange(
      from: range.from.subtract(Duration(days: range.days)),
      to: range.from.subtract(const Duration(days: 1)),
      label: 'السابق',
    );
    final prevAsync = ref.watch(productionKpiProvider(
        (farmId: farmId, range: prevRange)));

    return currentAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('خطأ: $e')),
      data: (current) {
        final prev = prevAsync.valueOrNull ?? ProductionKpi.empty();
        final change = current.totalEggs > 0 && prev.totalEggs > 0
            ? ((current.totalEggs - prev.totalEggs) / prev.totalEggs * 100)
            : 0.0;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _KpiGrid(
                items: [
                  _KpiData(
                    icon: Icons.egg_alt,
                    label: 'إجمالي البيض',
                    value: Formatters.formatNumber(current.totalEggs),
                    change: change,
                    color: Colors.orange,
                  ),
                  _KpiData(
                    icon: Icons.trending_up,
                    label: 'معدل الإنتاج',
                    value: '${current.productionRate.toStringAsFixed(1)}%',
                    color: Colors.blue,
                  ),
                  _KpiData(
                    icon: Icons.delete_outline,
                    label: 'بيض تالف',
                    value: Formatters.formatNumber(current.brokenEggs),
                    subtitle: 'معدل التلف: ${current.wasteRate.toStringAsFixed(1)}%',
                    color: Colors.red,
                  ),
                  _KpiData(
                    icon: Icons.calendar_today,
                    label: 'أيام بالبيانات',
                    value: '${current.daysWithData}',
                    color: Colors.green,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'الإجمالي = مجموع إنتاج الفترة المحددة فقط (غير تراكمي)، '
                'ويُضاف رصيد "التجهيز" القديم في النطاقات التي تشمل تاريخ تجهيزه.\n'
                'المعدل = إنتاج الفترة ÷ (عدد الطيور × أيام الفترة) × 100',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 24),
              _SectionTitle('مقارنة مع الفترة السابقة'),
              const SizedBox(height: 8),
              _ComparisonCard(
                label: 'الإنتاج',
                current: Formatters.formatNumber(current.totalEggs),
                previous: Formatters.formatNumber(prev.totalEggs),
                change: change,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Mortality Tab
// ═══════════════════════════════════════════════════════════════

class _MortalityTab extends ConsumerWidget {
  final String farmId;
  final DateRange range;

  const _MortalityTab({required this.farmId, required this.range});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mortalityKpiProvider(
        (farmId: farmId, range: range)));

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('خطأ: $e')),
      data: (kpi) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _KpiGrid(
                items: [
                  _KpiData(
                    icon: Icons.heart_broken,
                    label: 'إجمالي النفوق',
                    value: '${kpi.totalDeaths}',
                    color: kpi.level == 'danger'
                        ? Colors.red
                        : kpi.level == 'warning'
                            ? Colors.orange
                            : Colors.green,
                  ),
                  _KpiData(
                    icon: Icons.percent,
                    label: 'المعدل اليومي',
                    value: '${kpi.dailyRate.toStringAsFixed(3)}%',
                    subtitle: kpi.level == 'danger'
                        ? 'خطر'
                        : kpi.level == 'warning'
                            ? 'تحذير'
                            : 'طبيعي',
                    color: kpi.level == 'danger'
                        ? Colors.red
                        : kpi.level == 'warning'
                            ? Colors.orange
                            : Colors.green,
                  ),
                  _KpiData(
                    icon: Icons.calendar_today,
                    label: 'أيام بالبيانات',
                    value: '${kpi.daysWithData}',
                    color: Colors.blue,
                  ),
                ],
              ),
              if (kpi.deathsByReason.isNotEmpty) ...[
                const SizedBox(height: 24),
                _SectionTitle('الأسباب'),
                const SizedBox(height: 8),
                ...kpi.deathsByReason.entries.map((e) => Card(
                      child: ListTile(
                        leading: const Icon(Icons.bug_report),
                        title: Text(_reasonLabel(e.key)),
                        trailing: Text('${e.value}',
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
                      ),
                    )),
              ],
            ],
          ),
        );
      },
    );
  }

  String _reasonLabel(String reason) {
    const labels = {
      'not_eating': 'لا يأكل',
      'internal_bleeding': 'نزيف داخلي',
      'immunity_break': 'انهيار مناعة',
      'heat_stress': 'حرارة',
      'cannibalism': 'تعاض',
      'unknown': 'مجهول',
      'other': 'آخر',
      'opening_balance': 'رصيد افتتاحي',
    };
    return labels[reason] ?? reason;
  }
}

// ═══════════════════════════════════════════════════════════════
// Feed Tab
// ═══════════════════════════════════════════════════════════════

class _FeedTab extends ConsumerWidget {
  final String farmId;
  final DateRange range;

  const _FeedTab({required this.farmId, required this.range});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stock = ref.watch(feedStockProvider(farmId)).valueOrNull ?? 0;
    final async = ref.watch(feedKpiProvider(
        (farmId: farmId, range: range, stockKg: stock)));

        return async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('خطأ: $e')),
          data: (kpi) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _KpiGrid(
                    items: [
                      _KpiData(
                        icon: Icons.inbox,
                        label: 'المخزون الحالي',
                        value: '${Formatters.formatWeight(kpi.stockKg)}',
                        color: kpi.level == 'danger'
                            ? Colors.red
                            : kpi.level == 'warning'
                                ? Colors.orange
                                : Colors.green,
                      ),
                      _KpiData(
                        icon: Icons.timer,
                        label: 'أيام متبقية',
                        value: kpi.daysRemaining != null
                            ? '${kpi.daysRemaining!.toStringAsFixed(1)}'
                            : 'غير محدد',
                        color: kpi.level == 'danger'
                            ? Colors.red
                            : kpi.level == 'warning'
                                ? Colors.orange
                                : Colors.green,
                      ),
                      _KpiData(
                        icon: Icons.restaurant,
                        label: 'الاستهلاك اليومي',
                        value: '${Formatters.formatWeight(kpi.avgDailyConsumptionKg)}',
                        color: Colors.blue,
                      ),
                      _KpiData(
                        icon: Icons.local_shipping,
                        label: 'المستلم',
                        value: '${Formatters.formatWeight(kpi.receivedKg)}',
                        color: Colors.green,
                      ),
                      _KpiData(
                        icon: Icons.grass,
                        label: 'المستهلك',
                        value: '${Formatters.formatWeight(kpi.consumedKg)}',
                        color: Colors.brown,
                      ),
                      _KpiData(
                        icon: Icons.pets,
                        label: 'علف/طائر',
                        value: '${Formatters.formatWeight(kpi.feedPerBird)}',
                        color: Colors.teal,
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
  }
}

class _FlockTab extends ConsumerWidget {
  final String farmId;
  final DateRange range;

  const _FlockTab({required this.farmId, required this.range});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flocksAsync = ref.watch(flocksListProvider(farmId));

    return flocksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40),
            const SizedBox(height: 8),
            const Text('تعذّر تحميل القطعان'),
            const SizedBox(height: 4),
            Text(
              'لا توجد قطعان نشطة محلياً أو تعذّر الوصول للسحابة.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () => ref.invalidate(flocksListProvider(farmId)),
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
      data: (flocks) {
        final activeFlocks =
            flocks.where((f) => f.status == FlockStatus.active).toList();

        if (activeFlocks.isEmpty) {
          return const Center(child: Text('لا توجد قطعان نشطة'));
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: activeFlocks.length,
          itemBuilder: (context, i) {
            final flock = activeFlocks[i];
            return _FlockPerformanceCard(
              flock: flock,
              range: range,
            );
          },
        );
      },
    );
  }
}

class _FlockPerformanceCard extends ConsumerWidget {
  final FlockModel flock;
  final DateRange range;

  const _FlockPerformanceCard({
    required this.flock,
    required this.range,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(effectiveFlockCountsProvider(flock.farmId));
    final effective = counts.value?[flock.id] ?? flock.currentCount;
    final perfAsync = ref.watch(flockPerformanceProvider(
        (flock: flock.copyWith(currentCount: effective),
            range: range,
            pricePerEgg: 0)));

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: perfAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text('خطأ: $e'),
        ),
        data: (perf) {
          return ExpansionTile(
            title: Text('${flock.breed} — $effective طائر'),
            subtitle: Text('عمر: ${perf.ageDays} يوم'),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _KpiGrid(items: [
                      _KpiData(
                        icon: Icons.egg_alt,
                        label: 'بيض/طائر',
                        value: perf.eggsPerBird.toStringAsFixed(1),
                        color: Colors.orange,
                      ),
                      _KpiData(
                        icon: Icons.trending_up,
                        label: 'معدل الإنتاج',
                        value: '${perf.production.productionRate.toStringAsFixed(1)}%',
                        color: Colors.blue,
                      ),
                      _KpiData(
                        icon: Icons.heart_broken,
                        label: 'النفوق',
                        value: perf.mortality.totalDeaths.toString(),
                        subtitle: '${perf.mortality.dailyRate.toStringAsFixed(3)}%',
                        color: perf.mortality.level == 'danger'
                            ? Colors.red
                            : Colors.green,
                      ),
                      _KpiData(
                        icon: Icons.grass,
                        label: 'علف/طائر',
                        value: '${Formatters.formatWeight(perf.feedPerBird)}',
                        color: Colors.brown,
                      ),
                    ]),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Customer 360 Tab
// ═══════════════════════════════════════════════════════════════

class _CustomerTab extends ConsumerWidget {
  final String farmId;

  const _CustomerTab({required this.farmId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(customerAnalyticsProvider(farmId));

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('خطأ: $e')),
      data: (customers) {
        if (customers.isEmpty) {
          return const Center(child: Text('لا يوجد عملاء'));
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: customers.length,
          itemBuilder: (context, i) {
            final c = customers[i];
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: c.classification == 'good'
                      ? Colors.green
                      : c.classification == 'attention'
                          ? Colors.red
                          : Colors.grey,
                  child: Text(c.name[0],
                      style: const TextStyle(color: Colors.white)),
                ),
                title: Text(c.name),
                subtitle: Text(c.phone),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(Formatters.formatCurrency(c.totalSales),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    if (c.outstanding > 0)
                      Text(
                        'معلق: ${Formatters.formatCurrency(c.outstanding)}',
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Supplier Intelligence Tab
// ═══════════════════════════════════════════════════════════════

class _SupplierTab extends ConsumerWidget {
  final String farmId;
  final DateRange range;

  const _SupplierTab({required this.farmId, required this.range});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(supplierAnalyticsProvider(
        (farmId: farmId, range: range)));

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('خطأ: $e')),
      data: (suppliers) {
        if (suppliers.isEmpty) {
          return const Center(child: Text('لا توجد بيانات موردين'));
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: suppliers.length,
          itemBuilder: (context, i) {
            final s = suppliers[i];
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.supplierName,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _MiniStat('الشحنات', '${s.totalShipments}'),
                        _MiniStat('الكمية', '${Formatters.formatWeight(s.totalKg)}'),
                        _MiniStat('متوسط السعر', '${s.avgPricePerKg.toStringAsFixed(2)} \$/كغ'),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Cost Per Egg Tab
// ═══════════════════════════════════════════════════════════════

class _CostTab extends ConsumerWidget {
  final String farmId;
  final DateRange range;

  const _CostTab({required this.farmId, required this.range});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(costPerEggProvider(
        (farmId: farmId, range: range)));

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('خطأ: $e')),
      data: (cost) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _KpiGrid(items: [
                _KpiData(
                  icon: Icons.account_balance,
                  label: 'تكلفة البيضة',
                  value: '${cost.costPerEgg.toStringAsFixed(4)} \$',
                  subtitle: 'تقديرية',
                  color: Colors.blue,
                ),
                _KpiData(
                  icon: Icons.grass,
                  label: 'تكلفة العلف',
                  value: Formatters.formatCurrency(cost.feedCost),
                  color: Colors.brown,
                ),
                _KpiData(
                  icon: Icons.receipt,
                  label: 'المصروفات',
                  value: Formatters.formatCurrency(cost.expensesCost),
                  color: Colors.orange,
                ),
                _KpiData(
                  icon: Icons.egg_alt,
                  label: 'إجمالي البيض',
                  value: Formatters.formatNumber(cost.totalEggs),
                  color: Colors.green,
                ),
              ]),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      Text('التكلفة الإجمالية: ${Formatters.formatCurrency(cost.totalCost)}'),
                      Text('عدد البيض: ${Formatters.formatNumber(cost.totalEggs)}'),
                      Text('التكلفة/بيضة: ${cost.costPerEgg.toStringAsFixed(4)} \$'),
                      const SizedBox(height: 8),
                      const Text(
                        'ملاحظة: التكلفة تقديرية — تشمل العلف والمصروفات المشتركة فقط.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Profitability Tab
// ═══════════════════════════════════════════════════════════════

class _ProfitabilityTab extends ConsumerWidget {
  final String farmId;
  final DateRange range;

  const _ProfitabilityTab({required this.farmId, required this.range});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final farmAsync =
        ref.watch(farmProfitabilityProvider((farmId: farmId, range: range)));
    final flocksAsync = ref.watch(flocksListProvider(farmId));

    return farmAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('خطأ في حساب الربحية: $e')),
      data: (farm) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FarmProfitSummary(farm: farm, range: range),
              const SizedBox(height: 20),
              flocksAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (e, _) => const SizedBox.shrink(),
                data: (flocks) {
                  final active = flocks
                      .where((f) => f.status == FlockStatus.active)
                      .toList();
                  if (active.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SectionTitle('أداء القطعان'),
                      const SizedBox(height: 8),
                      ...active.map((f) =>
                          _FlockOpsCard(flock: f, range: range)),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FarmProfitSummary extends StatelessWidget {
  final FarmProfitability farm;
  final DateRange range;

  const _FarmProfitSummary({required this.farm, required this.range});

  @override
  Widget build(BuildContext context) {
    final marginColor = farm.margin >= 0 ? Colors.green : Colors.red;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.account_balance_wallet,
                    size: 22, color: Colors.indigo),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'الربحية — ${range.label}',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                if (farm.invoicedDispatches > 0)
                  Text(
                    '${farm.invoicedDispatches} فاتورة',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
              ],
            ),
            const Divider(),
            _ProfitLine(
              icon: Icons.egg_alt,
              label: 'إيرادات البيض',
              value: Formatters.formatCurrency(farm.revenue),
              color: Colors.blue,
            ),
            _ProfitLine(
              icon: Icons.payments,
              label: 'المقبوضات',
              value: Formatters.formatCurrency(farm.collected),
              color: Colors.green,
            ),
            if (farm.outstanding > 0.001)
              _ProfitLine(
                icon: Icons.hourglass_top,
                label: 'المستحق',
                value: Formatters.formatCurrency(farm.outstanding),
                color: Colors.orange,
              ),
            _ProfitLine(
              icon: Icons.grass,
              label: 'تكلفة العلف',
              value: Formatters.formatCurrency(farm.feedCost),
              color: Colors.brown,
            ),
            _ProfitLine(
              icon: Icons.receipt_long,
              label: 'مصاريف أخرى',
              value: Formatters.formatCurrency(farm.expensesCost),
              color: Colors.red.shade300,
            ),
            if (farm.invoicedDispatches == 0) ...[
              const Divider(),
              Text(
                'لا توجد فواتير مسعّرة في هذه الفترة — سجّل القبض من شاشة الدفعات لتظهر إيرادات البيض.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('صافي الربح',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
                Text(
                  '${Formatters.formatCurrency(farm.margin)}'
                  '${farm.revenue > 0 ? '  (${farm.marginPercent.toStringAsFixed(1)}%)' : ''}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                    color: marginColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// بطاقة أداء قطيع (إنتاج/علف/نفوق فقط — الإيرادات تُعرض على مستوى المزرعة)
class _FlockOpsCard extends ConsumerWidget {
  final FlockModel flock;
  final DateRange range;

  const _FlockOpsCard({required this.flock, required this.range});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(effectiveFlockCountsProvider(flock.farmId));
    final effective = counts.value?[flock.id] ?? flock.currentCount;
    final perfAsync = ref.watch(flockPerformanceProvider(
        (flock: flock.copyWith(currentCount: effective),
            range: range,
            pricePerEgg: 0)));

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: perfAsync.when(
        loading: () => const SizedBox(
            height: 56,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
        error: (e, _) =>
            Padding(padding: const EdgeInsets.all(12), child: Text('خطأ: $e')),
        data: (p) => ListTile(
          dense: true,
          leading: const Icon(Icons.pets, size: 20, color: Colors.blue),
          title: Text(flock.breed,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text('$effective طائر — ${flock.ageLabel}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FlockMini(
                  Icons.egg_alt, '${p.production.totalEggs}', Colors.orange),
              const SizedBox(width: 8),
              _FlockMini(
                  Icons.grass, Formatters.formatWeight(p.feed.consumedKg),
                  Colors.green),
              const SizedBox(width: 8),
              _FlockMini(Icons.heart_broken, '${p.mortality.totalDeaths}',
                  Colors.red),
            ],
          ),
        ),
      ),
    );
  }
}

class _FlockMini extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _FlockMini(this.icon, this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }
}

class _ProfitLine extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _ProfitLine({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Text(value,
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Shared Widgets
// ═══════════════════════════════════════════════════════════════

class _KpiGrid extends StatelessWidget {
  final List<_KpiData> items;
  const _KpiGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: MediaQuery.of(context).size.width > 800 ? 4 : 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.8,
      children: items.map((item) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Icon(item.icon, size: 16, color: item.color),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.color,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  item.value,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: item.color,
                  ),
                ),
                if (item.change != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${item.change! > 0 ? '+' : ''}${item.change!.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: item.change! > 0
                          ? Colors.green
                          : item.change! < 0
                              ? Colors.red
                              : Colors.grey,
                    ),
                  ),
                ],
                if (item.subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.subtitle!,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _KpiData {
  final IconData icon;
  final String label;
  final String value;
  final double? change;
  final String? subtitle;
  final Color color;

  const _KpiData({
    required this.icon,
    required this.label,
    required this.value,
    this.change,
    this.subtitle,
    required this.color,
  });
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
    );
  }
}

class _ComparisonCard extends StatelessWidget {
  final String label;
  final String current;
  final String previous;
  final double change;

  const _ComparisonCard({
    required this.label,
    required this.current,
    required this.previous,
    required this.change,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('الحالي: $current',
                    style: const TextStyle(fontSize: 18)),
                Text('السابق: $previous',
                    style: const TextStyle(color: Colors.grey)),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: change >= 0
                    ? Colors.green.withOpacity(0.1)
                    : Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: change >= 0 ? Colors.green : Colors.red,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;

  const _MiniStat(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}
