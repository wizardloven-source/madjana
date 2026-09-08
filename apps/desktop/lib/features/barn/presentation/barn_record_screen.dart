import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/design_tokens.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

/// سجل العنبر — بطاقة مراقبة يومية لكل عنبر داخل مدجنة
///
/// يُفتح من شاشة القطعان لقطيع معيّن. يعرض لكل عنبر:
/// - KPIs اليوم: إنتاج بيض، نفوق، استهلاك علف
/// - اتجاه آخر 7 أيام (إنتاج / نفوق)
/// - آخر الأحداث (تسجيل جديد / دواء)
class BarnRecordScreen extends ConsumerStatefulWidget {
  final FlockModel flock;

  const BarnRecordScreen({super.key, required this.flock});

  @override
  ConsumerState<BarnRecordScreen> createState() => _BarnRecordScreenState();
}

class _BarnRecordScreenState extends ConsumerState<BarnRecordScreen> {
  List<EggProductionModel> _eggs = [];
  List<MortalityModel> _mortality = [];
  List<FeedConsumptionModel> _feed = [];
  List<MedicationModel> _medications = [];
  bool _loading = true;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 6));
    final farmId = _farmId;
    try {
      final results = await Future.wait([
        ref
            .read(eggProductionRepositoryProvider)
            .getAllRecords(farmId: farmId, fromDate: from, toDate: now),
        ref
            .read(mortalityRepositoryProvider)
            .getAllRecords(farmId: farmId, fromDate: from, toDate: now),
        ref
            .read(feedRepositoryProvider)
            .getAllConsumption(farmId: farmId, fromDate: from, toDate: now),
        ref.read(medicationRepositoryProvider).getAll(
              farmId: farmId,
              fromDate: from,
              toDate: now,
            ),
      ]);
      if (!mounted) return;
      setState(() {
        _eggs = results[0] as List<EggProductionModel>;
        _mortality = results[1] as List<MortalityModel>;
        _feed = results[2] as List<FeedConsumptionModel>;
        _medications = results[3] as List<MedicationModel>;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // خلاصة لكل عنبر
    final perBarn = <int, _BarnSummary>{};
    for (final e in _eggs) {
      if (e.flockId == widget.flock.id) {
        perBarn
            .putIfAbsent(e.sectionNo ?? 1, () => _BarnSummary())
            .addEggs(e);
      }
    }
    for (final m in _mortality) {
      if (m.flockId == widget.flock.id) {
        perBarn
            .putIfAbsent(m.sectionNo ?? 1, () => _BarnSummary())
            .addMortality(m);
      }
    }
    for (final f in _feed) {
      if (f.flockId == widget.flock.id) {
        perBarn
            .putIfAbsent(f.sectionNo ?? 1, () => _BarnSummary())
            .addFeed(f);
      }
    }
    // أحدث الأحداث
    final events = <_BarnEvent>[
      for (final e in _eggs.where((x) => x.flockId == widget.flock.id))
        _BarnEvent(
          icon: Icons.egg_alt,
          color: AppStatusColors.success(context),
          text:
              'إنتاج ${Formatters.formatNumber(e.totalEggs)} بيضة — عنبر ${e.sectionNo ?? 1}',
          date: e.date,
        ),
      for (final m in _mortality.where((x) => x.flockId == widget.flock.id))
        _BarnEvent(
          icon: Icons.heart_broken,
          color: AppStatusColors.danger(context),
          text: 'نفوق ${m.count} — عنبر ${m.sectionNo ?? 1}',
          date: m.date,
        ),
      for (final md in _medications
          .where((x) => x.flockId == widget.flock.id))
        _BarnEvent(
          icon: Icons.medical_services,
          color: AppStatusColors.info(context),
          text: 'دواء: ${md.medicineName} (${md.dosage})',
          date: md.date,
        ),
    ]..sort((a, b) => b.date.compareTo(a.date));

    final barns = perBarn.keys.toList()..sort();
    if (barns.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: Text('سجل العنبر — ${widget.flock.displayName}'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _BarnHeaderCard(
                  label: 'إجمالي الطيور',
                  value: Formatters.formatNumber(widget.flock.currentCount),
                  icon: Icons.pets,
                  color: theme.colorScheme.primary,
                ),
                _BarnHeaderCard(
                  label: 'عدد العنابر',
                  value: '${widget.flock.sectionsCount}',
                  icon: Icons.meeting_room,
                  color: AppStatusColors.info(context),
                ),
                _BarnHeaderCard(
                  label: 'تاريخ البدء',
                  value:
                      '${widget.flock.startDate.day}/${widget.flock.startDate.month}',
                  icon: Icons.calendar_today,
                  color: AppStatusColors.warning(context),
                ),
                if (widget.flock.status == FlockStatus.depleted)
                  _BarnHeaderCard(
                    label: 'الحالة',
                    value: 'منتهي',
                    icon: Icons.flag,
                    color: AppStatusColors.danger(context),
                  ),
              ],
            ),
            const SizedBox(height: 24),

            if (barns.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      'لا تسجيلات بعد لهذه المدجنة',
                      style: TextStyle(color: theme.hintColor),
                    ),
                  ),
                ),
              )
            else
              for (final barnNo in barns) ...[
                _BarnSection(
                  barnNo: barnNo,
                  summary: perBarn[barnNo]!,
                  sectionsCount: widget.flock.sectionsCount,
                ),
                const SizedBox(height: 20),
              ],

            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.history,
                            color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        const Text('أحدث الأحداث',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (events.isEmpty)
                      Text('لا أحداث بعد',
                          style: TextStyle(color: theme.hintColor))
                    else
                      for (final ev in events.take(10))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(ev.icon, size: 16, color: ev.color),
                              const SizedBox(width: 8),
                              Expanded(child: Text(ev.text,
                                  style:
                                      const TextStyle(fontSize: 13))),
                              Text(
                                '${ev.date.day}/${ev.date.month}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarnSummary {
  int eggsToday = 0;
  int eggs7 = 0;
  int mortalityToday = 0;
  int mortality7 = 0;
  double feed7 = 0; // كغ
  final Map<DateTime, int> _dailyEggs = {};
  final Map<DateTime, int> _dailyMort = {};

  void addEggs(EggProductionModel e) {
    final key = DateTime(e.date.year, e.date.month, e.date.day);
    _dailyEggs[key] = (_dailyEggs[key] ?? 0) + e.totalEggs;
    if (_isToday(e.date)) eggsToday += e.totalEggs;
    eggs7 += e.totalEggs;
  }

  void addMortality(MortalityModel m) {
    final key = DateTime(m.date.year, m.date.month, m.date.day);
    _dailyMort[key] = (_dailyMort[key] ?? 0) + m.count;
    if (_isToday(m.date)) mortalityToday += m.count;
    mortality7 += m.count;
  }

  void addFeed(FeedConsumptionModel f) {
    feed7 += f.quantityKg;
  }

  List<int> get eggsLast7 {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    return [
      for (var i = 6; i >= 0; i--)
        _dailyEggs[start.subtract(Duration(days: i))] ?? 0,
    ];
  }

  List<int> get mortLast7 {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    return [
      for (var i = 6; i >= 0; i--)
        _dailyMort[start.subtract(Duration(days: i))] ?? 0,
    ];
  }

  bool get hasData => eggs7 > 0 || mortality7 > 0;

  static bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year &&
        d.month == now.month &&
        d.day == now.day;
  }
}

class _BarnHeaderCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _BarnHeaderCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(value,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarnSection extends StatelessWidget {
  final int barnNo;
  final _BarnSummary summary;
  final int sectionsCount;

  const _BarnSection({
    required this.barnNo,
    required this.summary,
    required this.sectionsCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!summary.hasData) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.meeting_room_outlined),
          title: Text('العنبر رقم $barnNo'),
          subtitle: const Text('لا تسجيلات بعد'),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text('العنبر رقم $barnNo',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('$sectionsCount عنابر',
                    style: TextStyle(
                        fontSize: 12, color: theme.colorScheme.outline)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _BarnKpi(
                    label: 'إنتاج اليوم',
                    value: Formatters.formatNumber(summary.eggsToday),
                    icon: Icons.egg_alt,
                    color: AppStatusColors.success(context),
                  ),
                ),
                Expanded(
                  child: _BarnKpi(
                    label: 'نفوق اليوم',
                    value: '${summary.mortalityToday}',
                    icon: Icons.heart_broken,
                    color: AppStatusColors.danger(context),
                  ),
                ),
                Expanded(
                  child: _BarnKpi(
                    label: 'استهلاك الأسبوع',
                    value: '${summary.feed7.toStringAsFixed(0)} كغ',
                    icon: Icons.grass,
                    color: AppStatusColors.warning(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // اتجاه آخر 7 أيام
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _MiniTrendChart(
                    label: 'الإنتاج (7 أيام)',
                    values: summary.eggsLast7,
                    color: AppStatusColors.success(context),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _MiniTrendChart(
                    label: 'النفوق (7 أيام)',
                    values: summary.mortLast7,
                    color: AppStatusColors.danger(context),
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

class _BarnKpi extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _BarnKpi({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            Text(value,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: color)),
          ],
        ),
      ],
    );
  }
}

/// مخطط شريطي مصغّر لاتجاه 7 أيام
class _MiniTrendChart extends StatelessWidget {
  final String label;
  final List<int> values;
  final Color color;

  const _MiniTrendChart({
    required this.label,
    required this.values,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = (values.reduce((a, b) => a > b ? a : b) <= 0)
        ? 1.0
        : values.reduce((a, b) => a > b ? a : b).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 11, color: theme.colorScheme.outline)),
        const SizedBox(height: 6),
        SizedBox(
          height: 44,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < values.length; i++) ...[
                Expanded(
                  child: Container(
                    height: 8 +
                        (44 - 8) * (values[i] / max).clamp(0, 1),
                    margin:
                        const EdgeInsets.symmetric(horizontal: 1.5),
                    decoration: BoxDecoration(
                      color:
                          color.withValues(alpha: i == values.length - 1 ? 1 : 0.6),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _BarnEvent {
  final IconData icon;
  final Color color;
  final String text;
  final DateTime date;

  const _BarnEvent({
    required this.icon,
    required this.color,
    required this.text,
    required this.date,
  });
}