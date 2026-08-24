import 'package:flutter/material.dart';
import 'package:core/core.dart';

/// الثيم العام لتطبيق سطح المكتب
class AppTheme {
  /// الثيم الداكن (الافتراضي)
  static ThemeData darkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: Color(AppConstants.colorInfo),
        secondary: Color(AppConstants.colorSuccess),
        surface: Color(0xFF121212),
        error: Color(AppConstants.colorDanger),
        onSurface: Colors.white,
      ),
      scaffoldBackgroundColor: const Color(0xFF121212),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey.shade900,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
      dataTableTheme: DataTableThemeData(
        headingTextStyle: const TextStyle(fontWeight: FontWeight.bold),
        dataTextStyle: const TextStyle(fontSize: 13),
      ),
    );
  }

  /// الثيم الفاتح
  static ThemeData lightTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: Color(AppConstants.colorInfo),
        secondary: Color(AppConstants.colorSuccess),
        surface: Colors.white,
        error: Color(AppConstants.colorDanger),
      ),
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        centerTitle: true,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey.shade100,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
      dataTableTheme: const DataTableThemeData(
        headingTextStyle: TextStyle(fontWeight: FontWeight.bold),
        dataTextStyle: TextStyle(fontSize: 13),
      ),
    );
  }
}