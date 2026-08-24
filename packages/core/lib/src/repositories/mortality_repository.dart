import 'dart:io';
import 'package:core/core.dart';

/// واجهة مستودع النفوق
abstract class MortalityRepository {
  /// حفظ سجل محلياً (Offline-first)
  Future<void> saveLocal(MortalityModel record);

  /// جلب العدد الحالي للقطيع
  Future<int> getFlockCurrentCount(String flockId);

  /// جلب سجلات اليوم
  Future<List<MortalityModel>> getTodayRecords(String farmId);

  /// جلب كل السجلات (للتقارير)
  Future<List<MortalityModel>> getAllRecords({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  });

  /// مزامنة السجلات المعلقة
  Future<void> syncPendingRecords();

  /// رفع صورة إلى السحابة
  Future<String?> uploadImage(File imageFile, String recordId);
}