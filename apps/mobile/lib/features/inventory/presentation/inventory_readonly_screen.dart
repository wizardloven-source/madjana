import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/design_tokens.dart';
import '../../../core/providers.dart';

/// شاشة المخزون (قراءة فقط) — للعامل والمدير.
///
/// تعرض رصيد صحون الكرتون النظامية التي يديرها السيرفر تلقائيًا:
///   • فارغة: تزيد بشراء الكرتون، وتُستهلك بالإنتاج.
///   • معبئة: تزيد بالإنتاج، وتُستهلك بالتخريج.
/// كراتين البيض تُشتق من الصحون المعبئة. لا يوجد أي تعديل يدوي هنا.
class InventoryReadonlyScreen extends ConsumerWidget {
  const InventoryReadonlyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(trayStockProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('المخزون'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref.invalidate(trayStockProvider),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(trayStockProvider),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            async.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => _InfoTile(
                icon: Icons.error_outline,
                label: 'تعذّر تحميل المخزون',
                value: '$e',
                color: AppStatusColors.danger(context),
              ),
              data: (stock) {
                final nf = const _IntFmt();
                final cartons = stock.filled ~/ AppConstants.traysPerCarton;
                final remTrays = stock.filled % AppConstants.traysPerCarton;
                return Column(
                  children: [
                    _StatCard(
                      icon: Icons.inventory_2_outlined,
                      title: 'صحون فارغة',
                      value: nf.format(stock.empty),
                      subtitle: 'تزيد بشراء الكرتون · تُستهلك بالإنتاج',
                      color: AppStatusColors.info(context),
                    ),
                    const SizedBox(height: 12),
                    _StatCard(
                      icon: Icons.egg_alt_outlined,
                      title: 'صحون معبئة',
                      value: nf.format(stock.filled),
                      subtitle: 'تزيد بالإنتاج · تُستهلك بالتخريج',
                      color: AppStatusColors.success(context),
                    ),
                    const SizedBox(height: 12),
                    _StatCard(
                      icon: Icons.all_inbox_outlined,
                      title: 'كراتين معبئة (مشتقة)',
                      value: cartons > 0
                          ? '$cartons كرتون'
                              '${remTrays > 0 ? ' + $remTrays صحن' : ''}'
                          : (stock.filled > 0
                              ? '${stock.filled.toInt()} صحن'
                              : '0'),
                      subtitle:
                          '${AppConstants.traysPerCarton} صحن = كرتون · مشتقة من الصحون المعبئة',
                      color: AppColors.accent,
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface3,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'يُحدَّث الرصيد تلقائيًا على الخادم عند تسجيل الإنتاج أو '
                      'التخريج أو شراء الكرتون. هذه الشاشة للعرض فقط.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textTertiary,
                      ),
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

class _IntFmt {
  const _IntFmt();
  String format(double v) => v.round().toString();
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String subtitle;
  final Color color;

  const _StatCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: color.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textTertiary,
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

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(label),
        subtitle: Text(value),
      ),
    );
  }
}
