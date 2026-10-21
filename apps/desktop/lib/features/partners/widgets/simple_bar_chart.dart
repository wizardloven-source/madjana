import 'package:flutter/material.dart';

class SimpleBarChart extends StatelessWidget {
  final List<double> values;
  final List<String> labels;
  final Color? barColor;
  final double? maxValue;

  const SimpleBarChart({
    super.key,
    required this.values,
    required this.labels,
    this.barColor,
    this.maxValue,
  });

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const SizedBox.shrink();
    final max = maxValue ?? values.reduce((a, b) => a > b ? a : b);
    final color = barColor ?? Theme.of(context).colorScheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(values.length, (i) {
        final h = max > 0 ? (values[i] / max) * 120 : 0.0;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Container(
                  height: h.clamp(4.0, 120.0),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  labels.length > i ? labels[i] : '',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}