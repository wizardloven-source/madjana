import 'package:intl/intl.dart';
import '../constants/app_constants.dart';

/// دوال التنسيق
class Formatters {
  /// تنسيق التاريخ: يوم/شهر/سنة
  static String formatDate(DateTime date) {
    return DateFormat('dd/MM/yyyy').format(date);
  }

  /// تنسيق التاريخ مع اسم اليوم
  static String formatDateWithDay(DateTime date) {
    final dayName = DateFormat('EEEE', 'ar').format(date);
    return '${formatDate(date)} - $dayName';
  }

  /// تنسيق الأرقام بفاصل الآلاف
  static String formatNumber(num value) {
    return NumberFormat('#,###').format(value);
  }

  /// تنسيق الوزن
  static String formatWeight(double kg) {
    return '${kg.toStringAsFixed(2)} كغ';
  }

  /// تنسيق العملة
  static String formatCurrency(double amount, {String symbol = 'د.ع'}) {
    return '${formatNumber(amount)} $symbol';
  }
}

/// Extension Methods لتسهيل العمليات
extension IntEggExtensions on int {
  /// تحويل العدد إلى كراتين
  int get toCartons => this ~/ AppConstants.eggsPerCarton;

  /// الباقي بعد التحويل إلى كراتين (بالبيض)
  int get remainderAfterCartons => this % AppConstants.eggsPerCarton;
}