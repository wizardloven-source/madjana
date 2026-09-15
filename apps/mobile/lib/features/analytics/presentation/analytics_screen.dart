import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/analytics_providers.dart';

/// ═══════════════════════════════════════════════════════════════
/// شاشة التحليلات — Mobile
/// بطاقات KPIs + تنبيهات + رسم بياني مبسّط
/// ═══════════════════════════════════════════════════════════════
class AnalyticsScreen extends ConsumerStatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen> {
  DateRange _range = DateRange.last7Days();

  String get _farmId =>
      ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('التحليلات'),
        actions: [
          PopupMenuButton<DateRange>(
            icon: const Icon(Icons.date_range),
            onSelected: (r) => setState(() => _range = r),
            itemBuilder: (_) => [
              const PopupMenuItem(value: null, child: Text('فترة')),
              PopupMenuItem(
                  value: DateRange.today(), child: const Text('اليوم')),
              PopupMenuItem(
                  value: DateRange.last7Days(), child: const Text('آخر 7 أيام')),
              PopupMenuItem(
                  value: DateRange.last30Days(), child: const Text('آخر 30 يوم')),
              PopupMenuItem(
                  value: DateRange.thisMonth(), child: const Text('هذا الشهر')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => setState(() {}),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildProductionSection(),
              const SizedBox(height: 16),
              _buildMortalitySection(),
              const SizedBox(height: 16),
              _buildFeedSection(),
              const SizedBox(height: 16),
              _buildStockAlertsSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProductionSection() {
    final async = ref.watch(productionKpiProvider(
        (farmId: _farmId, range: _range)));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: async.when(
          loading: () => const Center(
              child: Padding(
            padding: EdgeInsets.all(8),
            child: CircularProgressIndicator(),
          )),
          error: (e, _) => Text('خطأ: $e'),
          data: (kpi) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.egg_alt, color: Colors.orange),
                  const SizedBox(width: 8),
                  Text('الإنتاج — ${_range.label}',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _MetricItem(
                      'البيض', Formatters.formatNumber(kpi.totalEggs)),
                  _MetricItem('المعدل',
                      '${kpi.productionRate.toStringAsFixed(1)}%'),
                  _MetricItem('التالف', '${kpi.brokenEggs + kpi.dirtyEggs}'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMortalitySection() {
    final async = ref.watch(mortalityKpiProvider(
        (farmId: _farmId, range: _range)));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: async.when(
          loading: () => const Center(
              child: Padding(
            padding: EdgeInsets.all(8),
            child: CircularProgressIndicator(),
          )),
          error: (e, _) => Text('خطأ: $e'),
          data: (kpi) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.heart_broken,
                      color: kpi.level == 'danger'
                          ? Colors.red
                          : kpi.level == 'warning'
                              ? Colors.orange
                              : Colors.green),
                  const SizedBox(width: 8),
                  Text('النفوق — ${_range.label}',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _MetricItem('النفوق', '${kpi.totalDeaths}'),
                  _MetricItem('المعدل', '${kpi.dailyRate.toStringAsFixed(3)}%'),
                  _MetricItem('الحالة',
                      kpi.level == 'danger' ? 'خطر' : kpi.level == 'warning' ? 'تحذير' : 'طبيعي',
                      color: kpi.level == 'danger'
                          ? Colors.red
                          : kpi.level == 'warning'
                              ? Colors.orange
                              : Colors.green),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeedSection() {
    return FutureBuilder<double>(
      future: ref.read(feedRepositoryProvider).getCurrentFeedStock(_farmId),
      builder: (context, stockSnap) {
        final stock = stockSnap.data ?? 0;
        final async = ref.watch(feedKpiProvider(
            (farmId: _farmId, range: _range, stockKg: stock)));

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: async.when(
              loading: () => const Center(
                  child: Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(),
              )),
              error: (e, _) => Text('خطأ: $e'),
              data: (kpi) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.grass,
                          color: kpi.level == 'danger'
                              ? Colors.red
                              : kpi.level == 'warning'
                                  ? Colors.orange
                                  : Colors.green),
                      const SizedBox(width: 8),
                      Text('العلف — ${_range.label}',
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _MetricItem('المخزون', Formatters.formatWeight(kpi.stockKg)),
                      _MetricItem('الأيام',
                          kpi.daysRemaining != null
                              ? '${kpi.daysRemaining!.toStringAsFixed(0)}'
                              : '—'),
                      _MetricItem('اليومي',
                          Formatters.formatWeight(kpi.avgDailyConsumptionKg)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStockAlertsSection() {
    final async = ref.watch(stockAlertsProvider(_farmId));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: async.when(
          loading: () => const Center(
              child: Padding(
            padding: EdgeInsets.all(8),
            child: CircularProgressIndicator(),
          )),
          error: (e, _) => Text('خطأ: $e'),
          data: (alerts) {
            final critical = alerts
                .where((a) => a.status == 'critical')
                .toList();
            final low =
                alerts.where((a) => a.status == 'low').toList();

            if (critical.isEmpty && low.isEmpty) {
              return Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green),
                  const SizedBox(width: 8),
                  Text('جميع المخزونات فوق الحد الأدنى',
                      style: Theme.of(context).textTheme.bodyMedium),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.warning_amber, color: Colors.orange),
                    const SizedBox(width: 8),
                    Text('تنبيهات المخزون',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 8),
                if (critical.isNotEmpty) ...[
                  const Text('حرج:', style: TextStyle(color: Colors.red)),
                  ...critical.map((a) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text('• ${a.itemName}: ${a.currentQuantity} ${a.unit}',
                            style: const TextStyle(color: Colors.red)),
                      )),
                ],
                if (low.isNotEmpty) ...[
                  const Text('منخفض:', style: TextStyle(color: Colors.orange)),
                  ...low.map((a) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text('• ${a.itemName}: ${a.currentQuantity} ${a.unit}',
                            style: const TextStyle(color: Colors.orange)),
                      )),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MetricItem extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _MetricItem(this.label, this.value, {this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
