/// # Design Tokens — تطبيق Madjana
///
/// مصدر الحقيقة الوحيد للقيم القياسية (مسافات، زوايا، خطوط، ألوان دلالية).
/// يجب أن يعتمد أي Widget جديد على هذه التوكنات بدلاً من قيم خام مبعثرة
/// في الشاشات. بهذا يمكن تغيير هوية التطبيق بالكامل من مكان واحد.
library;

import 'package:flutter/material.dart';

/// المسافات القياسية (8px grid)
abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  static const EdgeInsets insetXs = EdgeInsets.all(xs);
  static const EdgeInsets insetSm = EdgeInsets.all(sm);
  static const EdgeInsets insetMd = EdgeInsets.all(md);
  static const EdgeInsets insetLg = EdgeInsets.all(lg);
}

/// الزوايا الدائرية القياسية
abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double full = 9999;

  static const BorderRadius radiusSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius radiusMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius radiusLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius radiusXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius radiusFull =
      BorderRadius.all(Radius.circular(full));
}

/// الطباعة (Typography) — الإصدار والخطوط والمقاسات
abstract final class AppTypography {
  static const String fontFamily = 'Cairo';
  static const String bodyFontFamily = 'Tajawal';

  // Display / Headline
  static const double display = 28;
  static const double headline = 22;
  static const double title = 18;

  // Body
  static const double bodyLg = 16;
  static const double bodyMd = 14;
  static const double bodySm = 13;

  // Label
  static const double label = 15;
  static const double caption = 12;

  // Mobile touch-first: النص الأساسي 14–16
  static const double button = 16;
}

/// الألوان الدلالية — لون الهوية + ألوان الحالة فقط.
///
/// الهوية: الأخضر (Madjana).
/// الحالة: success / warning / danger / info.
/// لا تُستخدم ألوان حالة كألوان هوية، ولا تُستخدم ألوان عشوائية
/// (Colors.red / Colors.orange / Colors.blue) في الشاشات.
abstract final class AppColors {
  static const Color primary = Color(0xFF2E7D32);
  static const Color primaryDark = Color(0xFF1B5E20);

  static const Color success = Color(0xFF388E3C);
  static const Color warning = Color(0xFFF9A825);
  static const Color danger = Color(0xFFD32F2F);
  static const Color info = Color(0xFF1976D2);

  // الخلفيات (dark/light)
  static const Color bgDark = Color(0xFF0F1114);
  static const Color bgLight = Color(0xFFF5F7FA);
  static const Color surfaceDark = Color(0xFF1A1F25);
  static const Color surfaceLight = Colors.white;
}

/// ألوان الحالة الدلالية قابلة للتمييز في الوضعين الفاتح/الداكن.
///
/// بديل موحّد للاستخدام الصارم لـ theme.colorScheme، بحيث تبقى ألوان الحالة
/// متطابقة عبر كامل التطبيق (وليست مشتّتة كـ Colors.red / Colors.orange ...).
abstract final class AppStatusColors {
  static Color success(BuildContext context) => AppColors.success;
  static Color warning(BuildContext context) => AppColors.warning;
  static Color danger(BuildContext context) => AppColors.danger;
  static Color info(BuildContext context) => AppColors.info;
}
