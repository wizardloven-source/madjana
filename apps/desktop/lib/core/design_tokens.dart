/// # Design Tokens — Madjana Desktop (ERP)
///
/// مصدر الحقيقة للقيم القياسية على سطح المكتب.
/// شاشات كبيرة → مسافات أكبر، خط أساسي 13–15، تنقّل واضح ≥12.
library;

import 'package:flutter/material.dart';

abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  static const EdgeInsets insetMd = EdgeInsets.all(md);
  static const EdgeInsets insetLg = EdgeInsets.all(lg);
}

abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;

  static const BorderRadius radiusMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius radiusLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius radiusXl = BorderRadius.all(Radius.circular(xl));
}

abstract final class AppTypography {
  // Desktop: أساسي 13–15، عناوين 16–22، أرقام مهمة 18–28.
  static const double display = 24;
  static const double headline = 20;
  static const double title = 18;
  static const double bodyLg = 15;
  static const double bodyMd = 14;
  static const double bodySm = 13;
  static const double label = 14;
  static const double caption = 12;
  static const double nav = 13; // ≥12 كما يوصي التقييم
}

abstract final class AppColors {
  static const Color primary = Color(0xFF2E7D32);

  static const Color success = Color(0xFF388E3C);
  static const Color warning = Color(0xFFF9A825);
  static const Color danger = Color(0xFFD32F2F);
  static const Color info = Color(0xFF1976D2);

  // خلفيات
  static const Color bgDark = Color(0xFF0F1114);
  static const Color bgLight = Color(0xFFF5F7FA);
  static const Color surfaceDark = Color(0xFF1A1F25);
  static const Color surfaceLight = Colors.white;
  static const Color railDark = Color(0xFF161A1E);
  static const Color railLight = Colors.white;
}

/// ألوان الحالة الدلالية — ألوان الهوية والحالة فقط، لا ألوان عشوائية.
abstract final class AppStatusColors {
  static Color primary(BuildContext context) => AppColors.primary;
  static Color success(BuildContext context) => AppColors.success;
  static Color warning(BuildContext context) => AppColors.warning;
  static Color danger(BuildContext context) => AppColors.danger;
  static Color info(BuildContext context) => AppColors.info;
}
