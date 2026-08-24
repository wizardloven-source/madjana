/// الثوابت العامة للنظام
class AppConstants {
  // تحويلات البيض
  static const int eggsPerTray = 30;
  static const int traysPerCarton = 12;
  static const int eggsPerCarton = eggsPerTray * traysPerCarton; // 360

  // تحويلات العلف
  static const double kgPerBag = 24.0;
  static const double kgPerTon = 1000.0;

  // حدود UI
  static const int maxPinLength = 4;
  static const double buttonMinHeight = 56.0;
  static const int maxTrays = 11;
  static const int maxLooseEggs = 29;

  // ألوان
  static const int colorSuccess = 0xFF4CAF50;
  static const int colorDanger = 0xFFF44336;
  static const int colorInfo = 0xFF2196F3;
  static const int colorWarning = 0xFFFFC107;
}