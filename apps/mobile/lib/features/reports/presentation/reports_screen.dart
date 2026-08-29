import 'dart:io';
import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'package:path_provider/path_provider.dart';
import '../../auth/providers/auth_provider.dart';
import '../../egg_production/providers/egg_production_provider.dart';
import '../../mortality/providers/mortality_provider.dart';
import '../../feed_consumption/providers/feed_consumption_provider.dart';

/// شاشة التقارير المحسنة - للمدير فقط
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  bool _loading = true;
  List<EggProductionModel> _todayEggs = [];
  List<MortalityModel> _todayMortality = [];
  List<FeedConsumptionModel> _todayFeed = [];
  List<EggProductionModel> _weekEggs = [];
  List<MortalityModel> _weekMortality = [];
  List<FeedConsumptionModel> _weekFeed = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final user = ref.read(authProvider).currentUser;
    final farmId = user?.farmId ?? '';
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final weekAgo = now.subtract(const Duration(days: 7));

    final results = await Future.wait([
      ref.read(eggProductionProvider.notifier).getRecords(farmId: farmId, fromDate: todayStart, toDate: now),
      ref.read(mortalityProvider.notifier).getRecords(farmId: farmId, fromDate: todayStart, toDate: now),
      ref.read(feedConsumptionProvider.notifier).getAll(farmId: farmId, fromDate: todayStart, toDate: now),
      ref.read(eggProductionProvider.notifier).getRecords(farmId: farmId, fromDate: weekAgo, toDate: now),
      ref.read(mortalityProvider.notifier).getRecords(farmId: farmId, fromDate: weekAgo, toDate: now),
      ref.read(feedConsumptionProvider.notifier).getAll(farmId: farmId, fromDate: weekAgo, toDate: now),
    ]);

    if (mounted) setState(() {
      _todayEggs = results[0] as List<EggProductionModel>;
      _todayMortality = results[1] as List<MortalityModel>;
      _todayFeed = results[2] as List<FeedConsumptionModel>;
      _weekEggs = results[3] as List<EggProductionModel>;
      _weekMortality = results[4] as List<MortalityModel>;
      _weekFeed = results[5] as List<FeedConsumptionModel>;
      _loading = false;
    });
  }

  Future<void> _exportCsv() async {
    final todayEggs = _todayEggs.fold<int>(0, (s, e) => s + e.totalEggs);
    final weekEggs = _weekEggs.fold<int>(0, (s, e) => s + e.totalEggs);
    final todayMort = _todayMortality.fold<int>(0, (s, m) => s + m.count);
    final weekMort = _weekMortality.fold<int>(0, (s, m) => s + m.count);
    final todayFeed = _todayFeed.fold<double>(0, (s, f) => s + f.quantityKg);
    final weekFeed = _weekFeed.fold<double>(0, (s, f) => s + f.quantityKg);

    final csv = const ListToCsvConverter().convert([
      ['التقرير', 'اليوم', 'آخر 7 أيام'],
      ['إنتاج البيض', '$todayEggs', '$weekEggs'],
      ['النفوق', '$todayMort', '$weekMort'],
      ['استهلاك العلف (كغ)', '${todayFeed.toStringAsFixed(1)}', '${weekFeed.toStringAsFixed(1)}'],
    ]);

    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/report_${DateTime.now().millisecondsSinceEpoch}.csv');
      await file.writeAsString(csv);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم حفظ التقرير: ${file.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل التصدير: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final todayEggs = _todayEggs.fold<int>(0, (s, e) => s + e.totalEggs);
    final todayMort = _todayMortality.fold<int>(0, (s, m) => s + m.count);
    final todayFeed = _todayFeed.fold<double>(0, (s, f) => s + f.quantityKg);

    final weekEggs = _weekEggs.fold<int>(0, (s, e) => s + e.totalEggs);
    final weekMort = _weekMortality.fold<int>(0, (s, m) => s + m.count);
    final weekFeed = _weekFeed.fold<double>(0, (s, f) => s + f.quantityKg);

    // Build simple bar chart data for last 7 days
    final now = DateTime.now();
    final dailyEggs = <int>[];
    for (int i = 6; i >= 0; i--) {
      final day = now.subtract(Duration(days: i));
      final dayStart = DateTime(day.year, day.month, day.day);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final count = _weekEggs.where((e) =>
        e.date.isAfter(dayStart.subtract(const Duration(seconds: 1))) &&
        e.date.isBefore(dayEnd)
      ).fold<int>(0, (s, e) => s + e.totalEggs);
      dailyEggs.add(count);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('التقارير'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download),
            onPressed: _loading ? null : _exportCsv,
            tooltip: 'تصدير CSV',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('اليوم', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                _buildReportCard(icon: Icons.egg, title: 'إنتاج اليوم', value: Formatters.formatNumber(todayEggs), subtitle: 'بيضة', color: Colors.blue),
                const SizedBox(height: 8),
                _buildReportCard(icon: Icons.pets, title: 'نفوق اليوم', value: Formatters.formatNumber(todayMort), subtitle: 'طائر', color: Colors.red),
                const SizedBox(height: 8),
                _buildReportCard(icon: Icons.grain, title: 'استهلاك العلف', value: Formatters.formatWeight(todayFeed), subtitle: '', color: Colors.orange),
                const SizedBox(height: 24),

                const Text('آخر 7 أيام', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                _buildReportCard(icon: Icons.egg, title: 'إنتاج الأسبوع', value: Formatters.formatNumber(weekEggs), subtitle: 'بيضة', color: Colors.blue),
                const SizedBox(height: 8),
                _buildReportCard(icon: Icons.pets, title: 'نفوق الأسبوع', value: Formatters.formatNumber(weekMort), subtitle: 'طائر', color: Colors.red),
                const SizedBox(height: 8),
                _buildReportCard(icon: Icons.grain, title: 'علف الأسبوع', value: Formatters.formatWeight(weekFeed), subtitle: '', color: Colors.orange),
                const SizedBox(height: 24),

                // Simple bar chart
                const Text('معدل الإنتاج اليومي', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                _BarChart(data: dailyEggs),
                const SizedBox(height: 24),

                Text(
                  'تصدير CSV متاح من الزر في الأعلى',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
    );
  }

  Widget _buildReportCard({
    required IconData icon,
    required String title,
    required String value,
    required String subtitle,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 40, color: color),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 4),
                Text(
                  '$value ${subtitle.isNotEmpty ? ' $subtitle' : ''}',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BarChart extends StatelessWidget {
  final List<int> data;
  const _BarChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final maxVal = data.fold<int>(0, (s, v) => v > s ? v : s);
    final days = ['س', 'ح', 'ن', 'ث', 'ر', 'خ', 'ج'];
    final now = DateTime.now();
    final dayLabels = List.generate(7, (i) => days[(now.subtract(Duration(days: 6 - i)).weekday - 1) % 7]);

    return Container(
      height: 180,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(7, (i) {
          final fraction = maxVal > 0 ? data[i] / maxVal : 0.0;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text('${data[i]}', style: const TextStyle(fontSize: 10)),
                  const SizedBox(height: 4),
                  Container(
                    height: (fraction * 120).clamp(4.0, 120.0),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(dayLabels[i], style: const TextStyle(fontSize: 10)),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
