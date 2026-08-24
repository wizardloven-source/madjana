import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// لوحة أرقام مخصصة
/// - أزرار كبيرة تعمل بالقفازات
/// - ألوان متوافقة مع الوضع الليلي والنهاري
/// - اهتزاز لمسي عند اللمس
class CustomNumpad extends StatelessWidget {
  final void Function(String key) onKeyTap;
  final bool showDecimal;

  const CustomNumpad({
    super.key,
    required this.onKeyTap,
    this.showDecimal = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildRow(context, ['1', '2', '3']),
        _buildRow(context, ['4', '5', '6']),
        _buildRow(context, ['7', '8', '9']),
        _buildRow(context, [
          showDecimal ? '.' : 'clear',
          '0',
          'backspace',
        ]),
      ],
    );
  }

  Widget _buildRow(BuildContext context, List<String> keys) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: keys.map((key) => _buildKey(context, key)).toList(),
    );
  }

  Widget _buildKey(BuildContext context, String key) {
    final theme = Theme.of(context);
    IconData? icon;
    String label = key;

    if (key == 'backspace') {
      icon = Icons.backspace_outlined;
      label = '';
    } else if (key == 'clear') {
      icon = Icons.clear;
      label = '';
    }

    return Padding(
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        width: 60,
        height: 60,
        child: ElevatedButton(
          onPressed: () {
            HapticFeedback.selectionClick();
            onKeyTap(key);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.surfaceContainerHigh,
            foregroundColor: theme.colorScheme.onSurface,
            elevation: 0,
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 1,
              ),
            ),
          ),
          child: icon != null
              ? Icon(icon, size: 24)
              : Text(
                  label,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
        ),
      ),
    );
  }
}
