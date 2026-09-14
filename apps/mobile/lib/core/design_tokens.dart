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
  static const double xl2 = 28;
  static const double full = 9999;

  static const BorderRadius radiusSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius radiusMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius radiusLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius radiusXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius radiusXl2 = BorderRadius.all(Radius.circular(xl2));
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

/// لوحة الألوان الفاخرة — هوية زرقاء أنيقة للواجهة الداكنة.
///
/// مجموعة لونية واحدة صارمة تستخدمها كل الشاشات الجديدة:
/// - الخلفيات: طبقات داكنة باهتة (bg → surface3).
/// - النصوص: ثلاثية (أساسي / ثانوي / ثالثي مختفٍ).
/// - هوية: accent أزرق واحد + نسخته الشفافة accentSoft.
/// - حالة: success / error فقط.
/// ممنوع استخدام أي تدرجات أو ظلال أو ألوان خارج هذه القائمة.
abstract final class AppColors {
  static const Color primary = Color(0xFF4A8CFF);
  static const Color primaryDark = Color(0xFF2A6AE0);

  static const Color success = Color(0xFF4ADE80);
  static const Color warning = Color(0xFFF9A825);
  static const Color danger = Color(0xFFF87171);
  static const Color error = Color(0xFFF87171);
  static const Color info = Color(0xFF1976D2);

  // الخلفيات (dark/light)
  static const Color bgDark = Color(0xFF0E0F11);
  static const Color surfaceDark = Color(0xFF16181B);
  static const Color bgLight = Color(0xFFF5F7FA);
  static const Color surfaceLight = Colors.white;

  /// طبقات السطح الداكنة (توكنات Premium)
  static const Color bg = Color(0xFF0E0F11);
  static const Color surface1 = Color(0xFF16181B);
  static const Color surface2 = Color(0xFF1E2126);
  static const Color surface3 = Color(0xFF262A30);

  /// خط فاصل 1px شفاف
  static const Color hairline = Color(0x0FFFFFFF);

  /// نصوص
  static const Color textPrimary = Color(0xFFF4F5F7);
  static const Color textSecondary = Color(0xFF9BA1A9);
  static const Color textTertiary = Color(0xFF5E646C);

  /// الهوية الزرقاء + نسخته الشفافة
  static const Color accent = Color(0xFF4A8CFF);
  static const Color accentSoft = Color(0x1F4A8CFF);
}

/// مرادفات اللوحة الفاخرة للحالة (تمييز واضح في الوضع الداكن)
abstract final class AppStatusColors {
  static Color success(BuildContext context) => AppColors.success;
  static Color warning(BuildContext context) => AppColors.warning;
  static Color danger(BuildContext context) => AppColors.danger;
  static Color info(BuildContext context) => AppColors.info;
  static Color error(BuildContext context) => AppColors.error;
}
