import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// ثيم التطبيق الموحد - الألوان والخطوط والأحجام
class AppTheme {
  // الألوان الرئيسية
  static const Color primaryColor = Color(0xFF2E7D32); // أخضر غامق
  static const Color secondaryColor = Color(0xFF81C784); // أخضر فاتح
  static const Color accentColor = Color(0xFFFFA726); // برتقالي
  static const Color errorColor = Color(0xFFD32F2F); // أحمر
  static const Color warningColor = Color(0xFFFF9800); // أصفر برتقالي
  static const Color successColor = Color(0xFF388E3C); // أخضر نجاح
  static const Color infoColor = Color(0xFF1976D2); // أزرق معلومات
  
  // ألوان الخلفيات
  static const Color backgroundColor = Color(0xFFF5F5F5);
  static const Color cardColor = Colors.white;
  static const Color scaffoldBackgroundColor = Color(0xFFFAFAFA);
  
  // ألوان النصوص
  static const Color textPrimaryColor = Color(0xFF212121);
  static const Color textSecondaryColor = Color(0xFF757575);
  static const Color textHintColor = Color(0xFFBDBDBD);
  static const Color textOnPrimaryColor = Colors.white;
  
  // الخطوط
  static TextStyle get headingLarge => GoogleFonts.cairo(
    fontSize: 24,
    fontWeight: FontWeight.bold,
    color: textPrimaryColor,
    height: 1.3,
  );
  
  static TextStyle get headingMedium => GoogleFonts.cairo(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: textPrimaryColor,
    height: 1.3,
  );
  
  static TextStyle get headingSmall => GoogleFonts.cairo(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: textPrimaryColor,
    height: 1.3,
  );
  
  static TextStyle get bodyLarge => GoogleFonts.tajawal(
    fontSize: 16,
    fontWeight: FontWeight.normal,
    color: textPrimaryColor,
    height: 1.5,
  );
  
  static TextStyle get bodyMedium => GoogleFonts.tajawal(
    fontSize: 14,
    fontWeight: FontWeight.normal,
    color: textSecondaryColor,
    height: 1.5,
  );
  
  static TextStyle get bodySmall => GoogleFonts.tajawal(
    fontSize: 12,
    fontWeight: FontWeight.normal,
    color: textSecondaryColor,
    height: 1.4,
  );
  
  static TextStyle get buttonStyle => GoogleFonts.tajawal(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: textOnPrimaryColor,
    height: 1.4,
  );
  
  static TextStyle get captionStyle => GoogleFonts.tajawal(
    fontSize: 12,
    fontWeight: FontWeight.normal,
    color: textHintColor,
    height: 1.3,
  );
  
  // إنشاء ThemeData للتطبيق
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      primaryColor: primaryColor,
      scaffoldBackgroundColor: scaffoldBackgroundColor,
      cardColor: cardColor,
      colorScheme: ColorScheme.light(
        primary: primaryColor,
        secondary: secondaryColor,
        tertiary: accentColor,
        error: errorColor,
        surface: cardColor,
        background: scaffoldBackgroundColor,
        onPrimary: textOnPrimaryColor,
        onSecondary: textPrimaryColor,
        onError: textOnPrimaryColor,
        onSurface: textPrimaryColor,
        onBackground: textPrimaryColor,
      ),
      textTheme: TextTheme(
        displayLarge: headingLarge,
        displayMedium: headingMedium,
        displaySmall: headingSmall,
        headlineLarge: headingLarge,
        headlineMedium: headingMedium,
        headlineSmall: headingSmall,
        titleLarge: headingMedium,
        titleMedium: headingSmall,
        titleSmall: bodyLarge,
        bodyLarge: bodyLarge,
        bodyMedium: bodyMedium,
        bodySmall: bodySmall,
        labelLarge: buttonStyle,
        labelSmall: captionStyle,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: primaryColor,
        foregroundColor: textOnPrimaryColor,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.cairo(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: textOnPrimaryColor,
        ),
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 2,
        shadowColor: Colors.black12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: textOnPrimaryColor,
          elevation: 2,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: buttonStyle,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardColor,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: textHintColor.withOpacity(0.3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: textHintColor.withOpacity(0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: primaryColor, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: errorColor),
        ),
        labelStyle: bodyMedium,
        hintStyle: captionStyle,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accentColor,
        foregroundColor: textOnPrimaryColor,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: textHintColor.withOpacity(0.2),
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: textPrimaryColor,
        contentTextStyle: bodyMedium.copyWith(color: textOnPrimaryColor),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  
  // مسافات قياسية
  static const double spacingXxs = 4.0;
  static const double spacingXs = 8.0;
  static const double spacingSm = 12.0;
  static const double spacingMd = 16.0;
  static const double spacingLg = 24.0;
  static const double spacingXl = 32.0;
  static const double spacingXxl = 48.0;
  
  // زوايا دائرية قياسية
  static const double radiusSm = 4.0;
  static const double radiusMd = 8.0;
  static const double radiusLg = 12.0;
  static const double radiusXl = 16.0;
  static const double radiusFull = 9999.0;
}
