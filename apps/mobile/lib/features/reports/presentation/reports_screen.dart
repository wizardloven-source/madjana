import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../auth/providers/auth_provider.dart';
import '../../egg_production/providers/egg_production_provider.dart';
import '../../mortality/providers/mortality_provider.dart';
import '../../feed_consumption/providers/feed_consumption_provider.dart';

/// شاشة التقارير - للمدير فقط
class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).currentUser;
    final farmId = user?.farmId ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('التقارير')),
      body: FutureBuilder(
        future: _loadReports(ref, farmId),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snapshot.data;
          if (data == null) {
            return const Center(child: Text('لا توجد بيانات'));
          }

          final todayEggs = data['todayEggs'] as int;
          final todayMortality = data['todayMortality'] as int;
          final todayFeed = data['todayFeed'] as double;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildReportCard(
                icon: Icons.egg,
                title: 'إنتاج اليوم',
                value: Formatters.formatNumber(todayEggs),
                subtitle: 'بيضة',
                color: const Color(AppConstants.colorInfo),
              ),
              const SizedBox(height: 12),
              _buildReportCard(
                icon: Icons.pets,
                title: 'نفوق اليوم',
                value: Formatters.formatNumber(todayMortality),
                subtitle: 'طائر',
                color: const Color(AppConstants.colorDanger),
              ),
              const SizedBox(height: 12),
              _buildReportCard(
                icon: Icons.grain,
                title: 'استهلاك العلف اليوم',
                value: Formatters.formatWeight(todayFeed),
                subtitle: '',
                color: const Color(AppConstants.colorWarning),
              ),
              const SizedBox(height: 24),
              const Text(
                'ملاحظة: التقارير الكاملة (المالية والمقارنات والتصدير) متوفرة في تطبيق سطح المكتب.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          );
        },
      ),
    );
  }

  Future<Map<String, dynamic>> _loadReports(WidgetRef ref, String farmId) async {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);

    final eggs = await ref
        .read(eggProductionProvider.notifier)
        .getRecords(farmId: farmId, fromDate: todayStart, toDate: now);
    final mortality = await ref
        .read(mortalityProvider.notifier)
        .getRecords(farmId: farmId, fromDate: todayStart, toDate: now);
    final feed = await ref
        .read(feedConsumptionProvider.notifier)
        .getAll(farmId: farmId, fromDate: todayStart, toDate: now);

    final todayEggs = eggs.fold<int>(0, (sum, e) => sum + e.totalEggs);
    final todayMortality = mortality.fold<int>(0, (sum, m) => sum + m.count);
    final todayFeed = feed.fold<double>(0, (sum, f) => sum + f.quantityKg);

    return {
      'todayEggs': todayEggs,
      'todayMortality': todayMortality,
      'todayFeed': todayFeed,
    };
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 4),
              Text(
                '$value ${subtitle.isNotEmpty ? ' $subtitle' : ''}',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}