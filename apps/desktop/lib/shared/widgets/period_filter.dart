import 'package:flutter/material.dart';

/// فترات سريعة جاهزة
enum QuickPeriod { today, yesterday, last7, last30, all }

/// شريط فترة سريع موحّد لكل شاشات سطح المكتب
///
/// يعرض شرائح: اليوم / أمس / آخر 7 أيام / آخر 30 يوماً / الكل
/// ويستدعي [onChanged] بالنطاق الجديد. أزرار التاريخ المخصص تبقى
/// في الشاشة نفسها؛ عند اختيار نطاق لا يطابق أي شريحة تُزال التحديدات.
class QuickPeriodBar extends StatelessWidget {
  final DateTime fromDate;
  final DateTime toDate;
  final ValueChanged<({DateTime from, DateTime to})> onChanged;

  const QuickPeriodBar({
    super.key,
    required this.fromDate,
    required this.toDate,
    required this.onChanged,
  });

  QuickPeriod? get _matched {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = DateTime(fromDate.year, fromDate.month, fromDate.day);
    final to = DateTime(toDate.year, toDate.month, toDate.day);

    if (from == today && to == today) return QuickPeriod.today;
    if (from == today.subtract(const Duration(days: 1)) &&
        to == today.add(const Duration(days: 1))) {
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
          to: today.add(const Duration(seconds: 86399))
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
