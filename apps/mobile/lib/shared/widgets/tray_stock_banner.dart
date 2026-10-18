import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/design_tokens.dart';
import '../../../core/providers.dart';

/// شريط مخزون صحون الكرتون (قراءة فقط) — يُعرض في شاشتي الإنتاج والتخريج.
///
/// مصدر الرصيد السيرفر (triggers)، فلا يوجد أي إدخال هنا — عرض وتحذير فقط.
/// - في الإنتاج: يُستهلك الفارغ (بالعدد المطلوب) ويُنتج المعبأ.
/// - في التخريج: يُستهلك المعبأ فقط.
class TrayStockBanner extends ConsumerWidget {
  /// إجمالي البيض المُدخل حالياً، لحساب عدد الصحون المطلوبة.
  final int pendingEggs;

  /// true = العملية تستهلك الصحون المعبئة (الإنتاج ينتجها، التخريج يستهلكها).
  /// false = العملية تستهلك الصحون الفارغة (الإنتاج).
  final bool consumeFilled;

  const TrayStockBanner({
    super.key,
    required this.pendingEggs,
    this.consumeFilled = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(trayStockProvider);
    return async.maybeWhen(
      data: (stock) => _build(context, stock),
      orElse: () => const SizedBox.shrink(),
    );
  }

  Widget _build(BuildContext context, TrayStock stock) {
    final needed = pendingEggs <= 0
        ? 0
        : (pendingEggs / stock.eggsPerTray).ceil();
    final available = consumeFilled ? stock.filled : stock.empty;
    final short = needed > available;
    final danger = AppStatusColors.danger(context);
    final warn = AppStatusColors.warning(context);
    final ok = AppStatusColors.success(context);
    final accent = short ? danger : ok;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.inventory_2_outlined, size: 18, color: accent),
              const SizedBox(width: 8),
              Text(
                'مخزون صحون الكرتون',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: accent,
                ),
              ),
              const Spacer(),
              Text(
                'فارغة ${_fmt(stock.empty)}  ·  معبئة ${_fmt(stock.filled)}',
                style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
              ),
            ],
          ),
          if (needed > 0) ...[
            const SizedBox(height: 6),
            Text(
              consumeFilled
                  ? 'يحتاج هذا التخريج: $needed صحن معبأ'
                  : 'يحتاج هذا الإنتاج: $needed صحن فارغ',
              style: TextStyle(fontSize: 13, color: accent),
            ),
            if (short)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 16, color: danger),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'الرصيد لا يكفي — المتوفر ${_fmt(available)} من $needed. '
                        'سيُسمح بالحفظ ويُسجَّل النقص للمراجعة.',
                        style: TextStyle(fontSize: 12, color: warn),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  static String _fmt(double v) => v.round().toString();
}
