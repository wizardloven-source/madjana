import 'package:flutter/material.dart';
import 'design_tokens.dart';

class AppTheme {
  static ThemeData darkTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bgDark,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.railDark,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: AppTypography.title,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppColors.surfaceDark,
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
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md - 2,
        ),
        border: _border(),
        enabledBorder: _border(),
        focusedBorder: _border(color: scheme.primary, width: 1.5),
      ),
      dataTableTheme: DataTableThemeData(
        headingTextStyle: TextStyle(
          fontWeight: FontWeight.bold,
          color: scheme.onSurface,
          fontSize: AppTypography.bodyMd,
        ),
        dataTextStyle: TextStyle(
          fontSize: AppTypography.bodyMd,
          color: scheme.onSurface,
        ),
        headingRowColor: WidgetStatePropertyAll(
          scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        ),
        dataRowColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) {
            return scheme.surfaceContainerHighest.withValues(alpha: 0.15);
          }
          return null;
        }),
        horizontalMargin: AppSpacing.md,
        columnSpacing: AppSpacing.md,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: AppColors.railDark,
        indicatorColor: scheme.primaryContainer.withValues(alpha: 0.4),
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme:
            IconThemeData(color: scheme.onSurface.withValues(alpha: 0.6)),
        selectedLabelTextStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
          fontSize: AppTypography.nav,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: scheme.onSurface.withValues(alpha: 0.6),
          fontSize: AppTypography.caption,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.3),
        thickness: 1,
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: AppRadius.radiusXl),
        backgroundColor: const Color(0xFF1C2227),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.radiusMd),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppRadius.radiusMd),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: AppTypography.label, fontWeight: FontWeight.w700),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppRadius.radiusMd),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: AppTypography.label, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  static ThemeData lightTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bgLight,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.railLight,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: AppTypography.title,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppColors.surfaceLight,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.radiusLg,
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md - 2,
        ),
        border: _border(),
        enabledBorder: _border(),
        focusedBorder: _border(color: scheme.primary, width: 1.5),
      ),
      dataTableTheme: DataTableThemeData(
        headingTextStyle: TextStyle(
          fontWeight: FontWeight.bold,
          color: scheme.onSurface,
          fontSize: AppTypography.bodyMd,
        ),
        dataTextStyle: TextStyle(
          fontSize: AppTypography.bodyMd,
          color: scheme.onSurface,
        ),
        headingRowColor: WidgetStatePropertyAll(
          scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        ),
        dataRowColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) {
            return scheme.surfaceContainerHighest.withValues(alpha: 0.2);
          }
          return null;
        }),
        horizontalMargin: AppSpacing.md,
        columnSpacing: AppSpacing.md,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: AppColors.railLight,
        indicatorColor: scheme.primaryContainer.withValues(alpha: 0.4),
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme:
            IconThemeData(color: scheme.onSurface.withValues(alpha: 0.6)),
        selectedLabelTextStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
          fontSize: AppTypography.nav,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: scheme.onSurface.withValues(alpha: 0.6),
          fontSize: AppTypography.caption,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        thickness: 1,
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: AppRadius.radiusXl),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.radiusMd),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppRadius.radiusMd),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: AppTypography.label, fontWeight: FontWeight.w700),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppRadius.radiusMd),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: AppTypography.label, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  static InputBorder _border({Color? color, double width = 0}) =>
      OutlineInputBorder(
        borderRadius: AppRadius.radiusMd,
        borderSide: width == 0
            ? BorderSide.none
            : BorderSide(color: color!, width: width),
      );
}

