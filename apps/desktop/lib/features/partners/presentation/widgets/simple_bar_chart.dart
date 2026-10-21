import 'package:flutter/material.dart';

/// رسم بياني أعمدة بسيط بدون مكتبات خارجية.
/// يعرض كل قيمة كعمود مرتفع نسبياً proportionally للقيمة الأعلى، مع تسمية أسفل كل عمود.
class SimpleBarChart extends StatelessWidget {
  /// القيم الرقمية للأعمدة.
  final List<double> values;

  /// التسميات أسفل الأعمدة (مثل فترات أو أسماء).
  final List<String> labels;

  /// لون الأعمدة.
  final Color barColor;

  /// القيمة المرجعية لرفع العمود الأعلى إلى الارتفاع الأقصى؛ إن غُبِّطتُ تُستخدم القيمة الأكبر في [values].
  final double? maxValue;

  const SimpleBarChart({
    super.key,
    required this.values,
    required this.labels,
    this.barColor = Colors.indigo,
    this.maxValue,
  });

  double _getMax() {
    if (values.isEmpty) return 1;
    final m = maxValue;
    if (m != null && m > 0) return m;
    return values.reduce((a, b) => a > b ? a : b);
  }

  @override
  Widget build(BuildContext context) {
    final max = _getMax();
    if (values.isEmpty) {
      return const SizedBox(
        height: 180,
        child: Center(
          child: Text('لا توجد بيانات للعرض', style: TextStyle(fontSize: 13, color: Colors.grey)),
        ),
      );
    }

    return SizedBox(
      height: 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(values.length, (i) {
                final v = values[i];
                return Expanded(
                  flex: 1,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        height: max > 0 ? (v / max) * 130 : 0,
                        width: double.infinity,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: barColor,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (v == v.roundToDouble())
                        Text(v.toInt().toString(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600))
                      else
                        Text(v.toStringAsFixed(2), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(
                        labels[i],
                        style: const TextStyle(fontSize: 10),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}
