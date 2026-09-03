import 'package:flutter/material.dart';
import '../../../core/design_tokens.dart';

/// ═══════════════════════════════════════════════
/// مكونات واجهة موحدة حديثة لكل شاشات التطبيق
/// ═══════════════════════════════════════════════

/// تنبيهات موحدة بأيقونات وألوان دلالية
class AppSnack {
  AppSnack._();

  static void success(BuildContext context, String message) =>
      _show(context, message, Icons.check_circle_rounded,
          Theme.of(context).colorScheme.primary);

  static void error(BuildContext context, String message) =>
      _show(context, message, Icons.error_rounded,
          Theme.of(context).colorScheme.error);

  static void info(BuildContext context, String message) => _show(
      context, message, Icons.info_rounded, AppColors.info);

  static void warning(BuildContext context, String message) =>
      _show(context, message, Icons.warning_amber_rounded, AppColors.warning);

  static void _show(
      BuildContext context, String message, IconData icon, Color color) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: color.withValues(alpha: theme.brightness == Brightness.dark ? 1 : 0.92),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

/// بطاقة حقل رقمي للحقل النشط في لوحة الأرقام
class NumberTile extends StatelessWidget {
  final String label;
  final String value;
  final bool active;
  final VoidCallback onTap;
  final String? hint;

  const NumberTile({
    super.key,
    required this.label,
    required this.value,
    required this.active,
    required this.onTap,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: active
            ? theme.colorScheme.primary.withValues(alpha: 0.07)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: active
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          width: active ? 2 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: active
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (hint != null)
                        Text(
                          hint!,
                          style: TextStyle(
                            fontSize: 11,
                            color:
                                theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                          ),
                        ),
                    ],
                  ),
                ),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 150),
                  style: TextStyle(
                    fontSize: active ? 30 : 26,
                    fontWeight: FontWeight.bold,
                    color: active
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  child: Text(value),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// زر الحفظ الرئيسي الموحد
class PrimaryActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Future<void> Function()? onPressed;
  final Color? color;

  const PrimaryActionButton({
    super.key,
    required this.label,
    this.icon = Icons.save_outlined,
    this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton.icon(
        onPressed: onPressed == null ? null : () => onPressed!(),
        style: FilledButton.styleFrom(
          backgroundColor: color ?? theme.colorScheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        icon: const Icon(Icons.save_outlined, size: 22),
        label: Text(
          label,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
