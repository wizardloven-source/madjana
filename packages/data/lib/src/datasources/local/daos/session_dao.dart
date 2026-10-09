import 'dart:convert';

import '../local_database.dart';

/// DAO لإدارة جلسة المستخدم
class SessionDao {
  /// حفظ الجلسة
  Future<void> save({
    required String userId,
    required String farmId,
    String? rememberToken,
    String? userJson,
  }) async {
    final db = await LocalDatabase.database;
    await db.delete('session'); // مسح أي جلسة سابقة
    await db.insert('session', {
      'id': 1,
      'user_id': userId,
      'farm_id': farmId,
      'remember_token': rememberToken,
      'last_login': DateTime.now().toIso8601String(),
      'user_json': userJson,
    });
  }

  /// جلب الجلسة الحالية
  Future<Map<String, dynamic>?> get() async {
    final db = await LocalDatabase.database;
    final result = await db.query('session', where: 'id = 1');
    return result.isEmpty ? null : result.first;
  }

  /// تخزين/تحديث بيانات المستخدم (للاسترجاع بدون إنترنت)
  Future<void> saveUserJson(String userJson) async {
    final db = await LocalDatabase.database;
    await db.update(
      'session',
      {'user_json': userJson},
      where: 'id = 1',
    );
  }

  /// تحديث مزرعة الجلسة النشطة.
  ///
  /// `saveUserJson` وحده لا يكفي: يُحدّث user_json فقط، بينما
  /// `LocalDatabase.getActiveFarmId()` و`enqueueChange` يقرآن
  /// `session.farm_id`. بدون هذا التحديث يبقى الطابور على المزرعة القديمة
  /// بعد تبديل المزرعة، فتُنسب السجلات الجديدة للمزرعة السابقة.
  Future<void> updateActiveFarm(String farmId) async {
    if (farmId.trim().isEmpty) return;
    final db = await LocalDatabase.database;
    await db.update(
      'session',
      {'farm_id': farmId},
      where: 'id = 1',
    );
  }

  /// استرجاع المستخدم المخزن محلياً من صف الجلسة (يعمل بدون إنترنت)
  Map<String, dynamic>? getCachedUser(Map<String, dynamic>? session) {
    final json = session?['user_json'] as String?;
    if (json == null || json.isEmpty) return null;
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } on Exception {
      return null;
    }
  }

  /// مسح الجلسة (تسجيل الخروج)
  Future<void> clear() async {
    final db = await LocalDatabase.database;
    await db.delete('session');
  }

  /// التحقق من وجود جلسة
  Future<bool> hasSession() async {
    final session = await get();
    return session != null && session['user_id'] != null;
  }
}
