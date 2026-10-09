import 'package:flutter/material.dart';
import 'package:core/core.dart';

/// فترات سريعة جاهزة
enum QuickPeriod { today, yesterday, last7, last30, all }

/// مبدّل وضع التقرير (م11): فترة/تراكمي.
class ReportModeToggle extends StatelessWidget {
  final ReportMode mode;
  final ValueChanged<ReportMode> onChanged;

  const ReportModeToggle({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ReportMode>(
      segments: const [
        ButtonSegment(
          value: ReportMode.period,
          label: Text('فترة'),
          icon: Icon(Icons.date_range_outlined),
        ),
        ButtonSegment(
          value: ReportMode.cumulative,
          label: Text('تراكمي'),
          icon: Icon(Icons.forward_outlined),
        ),
      ],
      selected: {mode},
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

/// شريط فترة سريع موحّد لكل شاشات سطح المكتب
///
/// يعرض شرائح: اليوم / أمس / آخر 7 أيام / آخر 30 يوماً / الكل
/// ويستدعي [onChanged] بالنطاق الجديد. أزرار التاريخ المخصص تبقى
/// في الشاشة نفسها؛ عند اختيار نطاق لا يطابق أي شريحة تُزال التحديدات.
///
/// عند تمرير [mode] و[onModeChanged] معاً يظهر مبدّل وضع
/// «فترة / تراكمي» (م11) ملحق بالشريط.
class QuickPeriodBar extends StatelessWidget {
  final DateTime fromDate;
  final DateTime toDate;
  final ValueChanged<({DateTime from, DateTime to})> onChanged;

  /// وضع التقرير الحالي — اختياري؛ عند وروده مع [onModeChanged] يُعرض
  /// مبدّل [ReportModeToggle] في نهاية الشريط.
  final ReportMode? mode;
  final ValueChanged<ReportMode>? onModeChanged;

  const QuickPeriodBar({
    super.key,
    required this.fromDate,
    required this.toDate,
    required this.onChanged,
    this.mode,
    this.onModeChanged,
  });

  QuickPeriod? get _matched {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = DateTime(fromDate.year, fromDate.month, fromDate.day);
    final to = DateTime(toDate.year, toDate.month, toDate.day);

    if (from == today && to == today) return QuickPeriod.today;
    if (from == today.subtract(const Duration(days: 1)) &&
        // ═══ FIX: أمس = من أمس إلى نهاية أمس (كانت المقارنة add بدل subtract) ═══
        to == today.subtract(const Duration(days: 1))) {
      return QuickPeriod.yesterday;
    }
    if (to == today &&
        from == today.subtract(const Duration(days: 6))) {
      return QuickPeriod.last7;
    }
    if (to == today &&
        from == today.subtract(const Duration(days: 29))) {
      return QuickPeriod.last30;
    }
    if (from.year <= 2020) return QuickPeriod.all;
    return null;
  }

  void _apply(QuickPeriod period) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59);

    switch (period) {
      case QuickPeriod.today:
        onChanged((from: today, to: endOfDay));
      case QuickPeriod.yesterday:
        onChanged((
          from: today.subtract(const Duration(days: 1)),
          // ═══ FIX: إلى نهاية يوم أمس (كانت اليوم + 86399 ثانية) ═══
          to: today.subtract(const Duration(seconds: 1)),
        ));
      case QuickPeriod.last7:
        onChanged((from: today.subtract(const Duration(days: 6)), to: endOfDay));
      case QuickPeriod.last30:
        onChanged((from: today.subtract(const Duration(days: 29)), to: endOfDay));
      case QuickPeriod.all:
        onChanged((from: DateTime(2020), to: endOfDay));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('الفترة:',
            style: TextStyle(
                fontSize: 13, color: Theme.of(context).hintColor)),
        for (final period in QuickPeriod.values)
          ChoiceChip(
            label: Text(_label(period)),
            selected: _matched == period,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => _apply(period),
          ),
        if (mode != null && onModeChanged != null)
          ReportModeToggle(
            mode: mode!,
            onChanged: onModeChanged!,
          ),
      ],
    );
  }

  String _label(QuickPeriod period) {
    switch (period) {
      case QuickPeriod.today:
        return 'اليوم';
      case QuickPeriod.yesterday:
        return 'أمس';
      case QuickPeriod.last7:
        return 'آخر 7 أيام';
      case QuickPeriod.last30:
        return 'آخر 30 يوماً';
      case QuickPeriod.all:
        return 'الكل';
    }
  }
}
