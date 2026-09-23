import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';
import '../../onboarding/presentation/old_flock_wizard_screen.dart';
import '../../onboarding/presentation/new_flock_wizard_screen.dart';
import '../../barn/presentation/barn_record_screen.dart';
import 'flock_accounting_screen.dart';

class FlocksScreen extends ConsumerStatefulWidget {
  const FlocksScreen({super.key});

  @override
  ConsumerState<FlocksScreen> createState() => _FlocksScreenState();
}

class _FlockData {
  final FlockModel flock;
  final OpeningBalanceModel? opening;
  final int mortalityCount;
  final int totalEggs;
  final double feedKg;
  final double paymentsCollected;
  final double totalDue;
  final List<EggProductionModel> eggRecords;

  const _FlockData({
    required this.flock,
    this.opening,
    required this.mortalityCount,
    required this.totalEggs,
    required this.feedKg,
    required this.paymentsCollected,
    required this.totalDue,
    required this.eggRecords,
  });

  int get effectiveMortality =>
      mortalityCount + (opening?.mortalityCount ?? 0);

  /// العدد الأولي هو ما خُزِّن في القطيع فقط؛ `opening.initialBirds` يحمل
  /// نفس القيمة (في المعالج القديم) ولا يُضاف حتى لا يُحتسب مزدوجاً.
  int get effectiveInitial => flock.initialCount;

  /// العدد الفعلي المعروض بعد تلافي القيم القديمة/الفاسدة المخزنة.
  int get effectiveCurrent => flock.effectiveCurrentCount(
        openingMortality: opening?.mortalityCount ?? 0,
        dailyMortality: mortalityCount,
      );

  double get mortalityRate =>
      effectiveInitial == 0 ? 0 : (effectiveMortality / effectiveInitial * 100);

  double get eggProductionRate {
    if (effectiveCurrent <= 0 || totalEggs <= 0 || flock.ageInDays <= 0) {
      return 0;
    }
    // المعدل = بيض إجمالي ÷ (متوسط الطيور خلال العمر × الأيام) — المتوسط
    // أقرب لمجموع الطيور الحاضن كل يوم من العدد الحالي المتناقص.
    final avgBirds = (effectiveInitial + effectiveCurrent) / 2;
    if (avgBirds <= 0) return 0;
    return totalEggs / (avgBirds * flock.ageInDays) * 100;
  }

  double get feedConversionRatio {
    if (totalEggs <= 0) return 0;
    return feedKg / totalEggs;
  }

  double get profitLoss =>
      (totalDue + (opening?.totalRevenues ?? 0)) -
      ((opening?.totalPayments ?? 0) + paymentsCollected);
}

class _FlocksScreenState extends ConsumerState<FlocksScreen> {
  List<FlockModel> _flocks = [];
  bool _loading = true;
  bool _includeEnded = true;
  Map<String, _FlockData> _flockDataMap = {};

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _flockDataMap = {};
    });
    try {
      final flocks = await ref
          .read(flockRepositoryProvider)
          .getFlocks(_farmId, includeEnded: _includeEnded);
      if (!mounted) return;
      setState(() => _flocks = flocks);
      await _loadFlockData(flocks);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ في التحميل: $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadFlockData(List<FlockModel> flocks) async {
    final now = DateTime.now();
    final farmStart = DateTime(2020, 1, 1);

    final results = await Future.wait([
      ref.read(eggProductionRepositoryProvider).getAllRecords(
            farmId: _farmId,
            fromDate: farmStart,
            toDate: now,
          ),
      ref.read(mortalityRepositoryProvider).getAllRecords(
            farmId: _farmId,
            fromDate: farmStart,
            toDate: now,
          ),
      ref.read(feedRepositoryProvider).getAllConsumption(
            farmId: _farmId,
            fromDate: farmStart,
            toDate: now,
          ),
      ref.read(dispatchRepositoryProvider).getAll(
            farmId: _farmId,
            fromDate: farmStart,
            toDate: now,
          ),
      ref.read(paymentRepositoryProvider).getAll(
            farmId: _farmId,
            fromDate: farmStart,
            toDate: now,
          ),
      ref.read(openingBalanceRepositoryProvider).getForFarm(_farmId),
    ]);

    final allEggs = results[0] as List<EggProductionModel>;
    final allMortality = results[1] as List<MortalityModel>;
    final allFeed = results[2] as List<FeedConsumptionModel>;
    final allDispatches = results[3] as List<DispatchModel>;
    final allPayments = results[4] as List<PaymentModel>;
    final allOpenings = results[5] as List<OpeningBalanceModel>;

    final openingMap = <String, OpeningBalanceModel>{};
    for (final ob in allOpenings) {
      openingMap[ob.flockId] = ob;
    }

    final dispatchIdMap = <String, Set<String>>{};
    for (final d in allDispatches) {
      if (d.flockId != null && d.id != null) {
        dispatchIdMap.putIfAbsent(d.flockId!, () => <String>{});
        dispatchIdMap[d.flockId]!.add(d.id!);
      }
    }

    final dataMap = <String, _FlockData>{};
    for (final flock in flocks) {
      final flockId = flock.id;

      final flockMortality =
          allMortality.where((m) => m.flockId == flockId).toList();
      final mortalityCount =
          flockMortality.fold<int>(0, (s, m) => s + m.count);

      final flockEggs =
          allEggs.where((e) => e.flockId == flockId).toList();
      final totalEggs =
          flockEggs.fold<int>(0, (s, e) => s + e.totalEggs);

      final flockFeed =
          allFeed.where((f) => f.flockId == flockId).toList();
      final feedKg =
          flockFeed.fold<double>(0, (s, f) => s + f.quantityKg);

      final dispatchIds = dispatchIdMap[flockId] ?? <String>{};
      final flockPayments = allPayments
          .where((p) =>
              p.dispatchId != null && dispatchIds.contains(p.dispatchId))
          .toList();
      final paymentsCollected =
          flockPayments.fold<double>(0, (s, p) => s + p.amountPaid);
      final totalDue =
          flockPayments.fold<double>(0, (s, p) => s + p.totalDue);

      final opening = openingMap[flockId];

      dataMap[flockId] = _FlockData(
        flock: flock,
        opening: opening,
        mortalityCount: mortalityCount,
        totalEggs: totalEggs,
        feedKg: feedKg,
        paymentsCollected: paymentsCollected,
        totalDue: totalDue,
        eggRecords: flockEggs,
      );
    }

    if (!mounted) return;
    setState(() => _flockDataMap = dataMap);
  }

  Future<void> _endCycle(FlockModel flock) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إنهاء الدورة'),
        content: Text(
            'هل تريد إنهاء دورة قطيع "${flock.breed}"؟ لن يستقبل التطبيق تسجيلات جديدة له.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إنهاء الدورة')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(flockRepositoryProvider).endFlock(flock.id);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _showAddFlockOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'إضافة قطيع',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'اختر نوع الإضافة',
              style: TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Theme.of(context).colorScheme.primary),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const NewFlockWizardScreen(),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.add_circle_outline,
                          color: Theme.of(context).colorScheme.primary,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'قطيع جديد',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'فوج جديد تمامًا - أدخل العدد والتاريخ وعدد العنابر والعامل المسؤول',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.orange.shade300),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const OldFlockWizardScreen(),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.history,
                          color: Colors.orange,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'قطيع قديم',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.orange,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'قطيع يعمل قبل النظام - أدخل الأرصدة الافتتاحية لكل عنبر',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios,
                        size: 16,
                        color: Colors.orange.shade300,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _flocks.where((f) => f.status == FlockStatus.active);
    final totalBirds =
        active.fold<int>(0, (sum, f) => sum + f.currentCount);
    final totalActiveFlocks = active.length;

    double avgProductionRate = 0;
    double overallMortalityRate = 0;
    int totalEffectiveInitial = 0;
    int totalEffectiveMortality = 0;
    int totalProducedEggs = 0;

    for (final flock in active) {
      final data = _flockDataMap[flock.id];
      if (data != null) {
        totalEffectiveInitial += data.effectiveInitial;
        totalEffectiveMortality += data.effectiveMortality;
        totalProducedEggs += data.totalEggs;
      }
    }

    if (totalEffectiveInitial > 0) {
      overallMortalityRate =
          totalEffectiveMortality / totalEffectiveInitial * 100;
    }

    if (totalBirds > 0 && totalProducedEggs > 0) {
      avgProductionRate = totalProducedEggs / totalBirds * 100;
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _SummaryChip(
                    label: 'طيور نشطة',
                    value: Formatters.formatNumber(totalBirds),
                    icon: Icons.pets,
                    color: Colors.green,
                  ),
                  _SummaryChip(
                    label: 'قطعان نشطة',
                    value: '$totalActiveFlocks',
                    icon: Icons.category,
                    color: Colors.blue,
                  ),
                  _SummaryChip(
                    label: 'معدل الإنتاج',
                    value: '${avgProductionRate.toStringAsFixed(1)}%',
                    icon: Icons.egg,
                    color: Colors.orange,
                  ),
                  _SummaryChip(
                    label: 'نسبة النفوق',
                    value: '${overallMortalityRate.toStringAsFixed(1)}%',
                    icon: Icons.warning_amber,
                    color: Colors.red,
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    label: const Text('إظهار المنتهية'),
                    selected: _includeEnded,
                    onSelected: (v) {
                      _includeEnded = v;
                      _load();
                    },
                  ),
                  FilledButton.icon(
                    onPressed: _showAddFlockOptions,
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة قطيع'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Expanded(
                child: Center(child: CircularProgressIndicator()))
          else if (_flocks.isEmpty)
            const Expanded(
                child: Center(child: Text('لا توجد قطعان مسجلة')))
          else
            Expanded(
              child: ListView.builder(
                itemCount: _flocks.length,
                itemBuilder: (context, index) {
                  final flock = _flocks[index];
                  final data = _flockDataMap[flock.id];
                  if (data == null) {
                    return _BasicFlockCard(flock: flock);
                  }
                  return _EnhancedFlockCard(
                    data: data,
                    onEndCycle: () => _endCycle(flock),
                    onViewBarn: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => BarnRecordScreen(flock: flock)),
                    ),
                    onAccounting: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => FlockAccountingScreen(flock: flock)),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _SummaryChip({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BasicFlockCard extends StatelessWidget {
  final FlockModel flock;
  const _BasicFlockCard({required this.flock});

  @override
  Widget build(BuildContext context) {
    final ended = flock.status == FlockStatus.depleted;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          ended ? Icons.history : Icons.pets,
          color: ended ? Colors.orange : Theme.of(context).colorScheme.primary,
        ),
        title: Text(flock.breed),
        subtitle: Text('العمر: ${flock.ageLabel}'),
        trailing: Chip(
          label: Text(ended ? 'منتهي' : 'نشط'),
          backgroundColor: ended ? Colors.grey.shade200 : Colors.green.shade100,
        ),
      ),
    );
  }
}

class _EnhancedFlockCard extends StatelessWidget {
  final _FlockData data;
  final VoidCallback onEndCycle;
  final VoidCallback onViewBarn;
  final VoidCallback onAccounting;

  const _EnhancedFlockCard({
    required this.data,
    required this.onEndCycle,
    required this.onViewBarn,
    required this.onAccounting,
  });

  @override
  Widget build(BuildContext context) {
    final flock = data.flock;
    final ended = flock.status == FlockStatus.depleted;
    final theme = Theme.of(context);
    final mortalityColor =
        data.mortalityRate > 5 ? Colors.red : Colors.green;
    final productionColor =
        data.eggProductionRate > 80
            ? Colors.green
            : data.eggProductionRate > 60
                ? Colors.orange
                : Colors.red;
    final profitLoss = data.profitLoss;
    final profitColor =
        profitLoss > 0 ? Colors.green : profitLoss < 0 ? Colors.red : Colors.grey;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  ended ? Icons.history : Icons.pets,
                  size: 28,
                  color:
                      ended ? Colors.orange : theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        flock.breed,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${DateFormat('yyyy/MM/dd').format(flock.startDate)}  |  ${flock.ageLabel}',
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(ended ? 'منتهي' : 'نشط'),
                  backgroundColor: ended
                      ? Colors.grey.shade200
                      : Colors.green.shade100,
                  padding: EdgeInsets.zero,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _FlockInfoChip(
                  label: 'الأولي',
                  value: '${data.effectiveInitial}',
                  color: Colors.blue,
                ),
                _FlockInfoChip(
                  label: 'الحالي',
                  value: '${data.effectiveCurrent}',
                  color: data.effectiveCurrent > data.effectiveInitial * 0.85
                      ? Colors.green
                      : Colors.red,
                ),
                _FlockInfoChip(
                  label: 'العنابر',
                  value: flock.sectionsCount > 1
                      ? '${flock.sectionsCount}'
                      : '1',
                  color: Colors.purple,
                ),
                if (data.effectiveMortality > 0)
                  _FlockInfoChip(
                    label: 'النفوق',
                    value: '${data.effectiveMortality}',
                    color: Colors.red,
                  ),
                _FlockInfoChip(
                  label: 'نسبة النفوق',
                  value: '${data.mortalityRate.toStringAsFixed(1)}%',
                  color: mortalityColor,
                ),
                _FlockInfoChip(
                  label: 'معدل الإنتاج',
                  value: '${data.eggProductionRate.toStringAsFixed(1)}%',
                  color: productionColor,
                ),
                if (data.feedKg > 0)
                  _FlockInfoChip(
                    label: 'علف/بيض',
                    value: data.feedConversionRatio > 0
                        ? '${data.feedConversionRatio.toStringAsFixed(2)}'
                        : '-',
                    color: Colors.teal,
                  ),
                if (data.totalDue > 0)
                  _FlockInfoChip(
                    label: 'المستحق',
                    value: Formatters.formatCurrency(data.totalDue),
                    color: Colors.indigo,
                  ),
                if (data.paymentsCollected > 0)
                  _FlockInfoChip(
                    label: 'المحصّل',
                    value: Formatters.formatCurrency(data.paymentsCollected),
                    color: Colors.green,
                  ),
                _FlockInfoChip(
                  label: 'المستحق (غير المحصّل)',
                  value: Formatters.formatCurrency(profitLoss),
                  color: profitColor,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: (data.effectiveCurrent / data.effectiveInitial)
                        .clamp(0.0, 1.0),
                    backgroundColor: Colors.grey.shade200,
                    color: data.effectiveCurrent > data.effectiveInitial * 0.85
                        ? Colors.green
                        : Colors.red,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${((data.effectiveCurrent / data.effectiveInitial) * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'سجل العنبر',
                  icon: const Icon(Icons.menu_book_outlined, size: 20),
                  onPressed: onViewBarn,
                ),
                IconButton(
                  tooltip: 'محاسبة الفوج',
                  icon: const Icon(Icons.account_balance_wallet_outlined,
                      size: 20),
                  onPressed: onAccounting,
                ),
                if (!ended)
                  IconButton(
                    tooltip: 'إنهاء الدورة',
                    icon: const Icon(Icons.flag_outlined, size: 20),
                    onPressed: onEndCycle,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FlockInfoChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _FlockInfoChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }
}
