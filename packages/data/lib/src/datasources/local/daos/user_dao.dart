import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import '../local_database.dart';

/// كاش محلي لمستخدمي المزرعة (يُملأ من السحابة عند المزامنة)
///
/// يتيح لشاشة "المستخدمون" العمل حتى بدون اتصال بالإنترنت
/// أو عند تعذّر قراءة السحابة مؤقتاً.
class UserDao {
  static const String _table = 'users';

  /// استبدال كامل لكاش مستخدمي المزرعة
  Future<void> upsertAll(String farmId, List<UserModel> users) async {
    final db = await LocalDatabase.database;
    for (final u in users) {
      await db.insert(
        _table,
        {
          'id': u.uid,
          'farm_id': u.farmId ?? farmId,
          'name': u.name,
          'phone': u.phone,
          'role': u.role.name,
          'created_at': u.createdAt.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    // حذف من الكاش أي مستخدمين لم يعودوا موجودين في القائمة الجديدة
    final ids = users.map((u) => u.uid).toList();
    if (ids.isNotEmpty) {
      final placeholders = List.filled(ids.length, '?').join(',');
      await db.delete(
        _table,
        where: 'farm_id = ? AND id NOT IN ($placeholders)',
        whereArgs: [farmId, ...ids],
      );
    }
  }

  Future<List<UserModel>> getByFarm(String farmId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'farm_id = ?',
      whereArgs: [farmId],
      orderBy: 'created_at',
    );
    return maps.map(_fromMap).toList();
  }

  UserModel _fromMap(Map<String, dynamic> map) {
    return UserModel(
      uid: map['id'] as String,
      name: map['name'] as String,
      phone: map['phone'] as String,
      role: UserRole.values.firstWhere(
        (e) => e.name == map['role'],
        orElse: () => UserRole.worker,
      ),
      farmId: map['farm_id'] as String?,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}