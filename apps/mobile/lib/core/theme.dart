import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'design_tokens.dart';

class AppTheme {
  static const Color seedColor = AppColors.primary;

  static ThemeData darkTheme() => _build(Brightness.dark);
  static ThemeData lightTheme() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );

    final baseText = GoogleFonts.cairoTextTheme(
      isDark
          ? ThemeData.dark().textTheme
          : ThemeData.light().textTheme,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      textTheme: baseText,

      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
        foregroundColor: scheme.onSurface,
        titleTextStyle: baseText.titleLarge?.copyWith(
          fontSize: AppTypography.title,
          fontWeight: FontWeight.bold,
          color: scheme.onSurface,
        ),
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.radiusLg,
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest
            .withValues(alpha: isDark ? 0.35 : 0.5),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm + 2,
        ),
        border: _filledBorder(),
        enabledBorder: _filledBorder(),
        focusedBorder: _filledBorder(color: scheme.primary, width: 1.5),
        errorBorder: _filledBorder(color: scheme.error, width: 1.5),
        focusedErrorBorder: _filledBorder(color: scheme.error, width: 2),
      ),

      filledButtonTheme: FilledButtonThemeData(style: _solid(scheme)),
      elevatedButtonTheme: ElevatedButtonThemeData(style: _elevated(scheme)),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md - 2,
          ),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.radiusMd),
          side: BorderSide(color: scheme.outline),
          textStyle: baseText.labelLarge?.copyWith(
            fontSize: AppTypography.button,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.radiusMd),
        elevation: 4,
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        thickness: 1,
        space: 1,
      ),

      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: AppRadius.radiusXl),
        backgroundColor:
            isDark ? const Color(0xFF1C2227) : AppColors.surfaceLight,
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? const Color(0xFF161B20) : Colors.white,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppSpacing.xl - 12)),
        ),
      ),

      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  static Color scaffold(bool isDark) =>
      isDark ? AppColors.bgDark : AppColors.bgLight;

  static InputBorder _filledBorder({Color? color, double width = 0}) =>
      OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        borderSide: width == 0
            ? BorderSide.none
            : BorderSide(color: color!, width: width),
      );

  static ButtonStyle _solid(ColorScheme scheme) => ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 52)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md - 2,
          ),
        ),
        backgroundColor: WidgetStatePropertyAll(scheme.primary),
        foregroundColor: WidgetStatePropertyAll(scheme.onPrimary),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontSize: AppTypography.button,
            fontWeight: FontWeight.w700,
          ),
        ),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppRadius.radiusMd),
        ),
      );

  static ButtonStyle _elevated(ColorScheme scheme) => ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 52)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md - 2,
          ),
        ),
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return scheme.onSurface.withValues(alpha: 0.12);
          }
          return scheme.primary;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return scheme.onSurface.withValues(alpha: 0.38);
          }
          return scheme.onPrimary;
        }),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontSize: AppTypography.button,
            fontWeight: FontWeight.w700,
          ),
        ),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppRadius.radiusMd),
        ),
      );
}
