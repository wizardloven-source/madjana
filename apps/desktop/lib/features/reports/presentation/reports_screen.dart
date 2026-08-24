import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/csv_exporter.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/period_filter.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة التقارير - ملخص شامل للمدير
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  List<EggProductionModel> _eggs = [];
  List<MortalityModel> _mortality = [];
  List<FeedConsumptionModel> _consumption = [];
  List<PaymentModel> _payments = [];
  int _birds = 0;
  double _feedStock = 0;
  bool _loading = true;
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate = DateTime.now();

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final eggRepo = ref.read(eggProductionRepositoryProvider);
    final mortRepo = ref.read(mortalityRepositoryProvider);
    final feedRepo = ref.read(feedRepositoryProvider);
    final paymentRepo = ref.read(paymentRepositoryProvider);

    final results = await Future.wait([
      eggRepo.getAllRecords(
        farmId: _farmId,
        fromDate: _fromDate,
        toDate: _toDate,
      ),
      mortRepo.getAllRecords(
        farmId: _farmId,
        fromDate: _fromDate,
        toDate: _toDate,
      ),
      feedRepo.getAllConsumption(
        farmId: _farmId,
        fromDate: _fromDate,
        toDate: _toDate,
      ),
      paymentRepo.getAll(
        farmId: _farmId,
        fromDate: _fromDate,
        toDate: _toDate,
      ),
      ref.read(flockRepositoryProvider).getFlocks(_farmId, includeEnded: true),
      feedRepo.getCurrentFeedStock(_farmId),
    ]);

    final flocks = results[4] as List<FlockModel>;
    if (!mounted) return;
    setState(() {
      _eggs = results[0] as List<EggProductionModel>;
      _mortality = results[1] as List<MortalityModel>;
      _consumption = results[2] as List<FeedConsumptionModel>;
      _payments = results[3] as List<PaymentModel>;
      _birds = flocks
          .where((f) => f.status == FlockStatus.active)
          .fold<int>(0, (s, f) => s + f.currentCount);
      _feedStock = results[5] as double;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final totalEggs = _eggs.fold<int>(0, (s, r) => s + r.totalEggs);
    final totalCartons = _eggs.fold<int>(0, (s, r) => s + r.cartons);
    final totalMortality = _mortality.fold<int>(0, (s, r) => s + r.count);
    final totalFeed = _consumption.fold<double>(0, (s, r) => s + r.quantityKg);
    final totalDue = _payments.fold<double>(0, (s, p) => s + p.totalDue);
    final totalCollected = _payments.fold<double>(0, (s, p) => s + p.amountPaid);
    final outstanding = totalDue - totalCollected;
    final avgPerDay = _eggs.isEmpty
        ? 0.0
        : totalEggs / (_toDate.difference(_fromDate).inDays + 1);

    // المؤشرات التحليلية
    final days = _toDate.difference(_fromDate).inDays + 1;
    final prodRate = FarmAnalytics.avgProductionRate(
        totalEggs: totalEggs, birdCount: _birds, days: days);
    final mortDailyRate = FarmAnalytics.dailyMortalityRate(
        totalDeaths: totalMortality, birdCount: _birds, days: days);
    final feedPerDay = totalFeed / days;
    final feedDaysLeft = FarmAnalytics.feedDaysLeft(
      stockKg: _feedStock,
      avgDailyConsumptionKg: feedPerDay,
    );

    Future<void> exportCsv() async {
      try {
        final path = await CsvExporter.saveCsv(
          fileName:
              'report_${Formatters.formatDate(_fromDate).replaceAll('/', '-')}_${Formatters.formatDate(_toDate).replaceAll('/', '-')}',
          rows: [
            ['التقرير', 'القيمة'],
            ['الفترة', '${Formatters.formatDate(_fromDate)} - ${Formatters.formatDate(_toDate)}'],
            ['إجمالي البيض', '$totalEggs'],
            ['إجمالي الكراتين', '$totalCartons'],
            ['المعدل اليومي', avgPerDay.toStringAsFixed(0)],
            ['معدل الإنتاج %', '${prodRate.toStringAsFixed(2)}%'],
            ['الطيور الحية', '$_birds'],
            ['إجمالي النفوق', '$totalMortality'],
            ['معدل النفوق اليومي %', '${mortDailyRate.toStringAsFixed(3)}%'],
            ['استهلاك العلف (كغ)', totalFeed.toStringAsFixed(0)],
            ['متوسط استهلاك العلف اليومي (كغ)', feedPerDay.toStringAsFixed(0)],
            [
              'المخزون الحالي يكفي (يوم)',
              feedDaysLeft == null ? 'غير معروف' : feedDaysLeft.toStringAsFixed(1)
            ],
            ['إجمالي المبيعات (المستحق)', totalDue.toStringAsFixed(2)],
            ['المقبوضات', totalCollected.toStringAsFixed(2)],
            ['المبالغ المستحقة', outstanding.toStringAsFixed(2)],
          ],
        );
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم حفظ التقرير: $path')),
        );
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل التصدير: $e')),
        );
      }
    }

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
              FilledButton.tonalIcon(
                onPressed: _loading ? null : exportCsv,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('تصدير CSV'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // ملخص الإنتاج
                        _SectionCard(
                          title: 'ملخص الإنتاج',
                          icon: Icons.egg_alt,
                          rows: [
                            ('إجمالي البيض', '${Formatters.formatNumber(totalEggs)} بيضة', null),
                            ('إجمالي الكراتين', Formatters.formatNumber(totalCartons), null),
                            ('المعدل اليومي', '${avgPerDay.toStringAsFixed(0)} بيضة/يوم', null),
                            (
                              'معدل الإنتاج',
                              '${prodRate.toStringAsFixed(1)}%',
                              prodRate >= 80
                                  ? Colors.green
                                  : (prodRate >= 60 ? Colors.orange : Colors.redAccent),
                            ),
                            ('الطيور الحية', Formatters.formatNumber(_birds), null),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // ملخص النفوق
                        _SectionCard(
                          title: 'ملخص النفوق',
                          icon: Icons.heart_broken,
                          rows: [
                            ('إجمالي النفوق', Formatters.formatNumber(totalMortality), null),
                            (
                              'معدل النفوق اليومي',
                              '${mortDailyRate.toStringAsFixed(3)}% / يوم',
                              FarmAnalytics.mortalityLevel(mortDailyRate) == 'danger'
                                  ? Colors.redAccent
                                  : (FarmAnalytics.mortalityLevel(mortDailyRate) == 'warning'
                                      ? Colors.orange
                                      : Colors.green),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // ملخص العلف
                        _SectionCard(
                          title: 'ملخص العلف',
                          icon: Icons.inventory_2,
                          rows: [
                            ('إجمالي الاستهلاك', '${Formatters.formatNumber(totalFeed.toInt())} كغ', null),
                            ('متوسط الاستهلاك اليومي', '${feedPerDay.toStringAsFixed(0)} كغ/يوم', null),
                            (
                              'المخزون الحالي (${Formatters.formatNumber(_feedStock.toInt())} كغ) يكفي',
                              feedDaysLeft == null
                                  ? 'غير معروف'
                                  : '~${feedDaysLeft.toStringAsFixed(1)} يوم',
                              FarmAnalytics.feedLevel(feedDaysLeft) == 'danger'
                                  ? Colors.redAccent
                                  : (FarmAnalytics.feedLevel(feedDaysLeft) == 'warning'
                                      ? Colors.orange
                                      : Colors.green),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // الملخص المالي
                        _SectionCard(
                          title: 'الملخص المالي',
                          icon: Icons.payments,
                          financial: true,
                          rows: [
                            ('إجمالي المبيعات (المستحق)', Formatters.formatCurrency(totalDue), null),
                            ('المقبوضات', Formatters.formatCurrency(totalCollected), null),
                            ('المبالغ المستحقة', Formatters.formatCurrency(outstanding),
                                outstanding > 0 ? Colors.deepOrangeAccent : Colors.greenAccent),
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

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<(String, String, Color?)> rows;
  final bool financial;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.rows,
    this.financial = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  color: financial ? Colors.greenAccent : Colors.amber,
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(),
            for (final (label, value, colorOverride) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(label, style: const TextStyle(color: Colors.grey)),
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: colorOverride ??
                            (financial
                                ? Colors.greenAccent
                                : Theme.of(context).colorScheme.onSurface),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}