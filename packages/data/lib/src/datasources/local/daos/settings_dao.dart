import 'package:sqflite/sqflite.dart';
import '../local_database.dart';

/// DAO لإعدادات التطبيق (مفتاح/قيمة)
class SettingsDao {
  static const String _table = 'app_settings';

  Future<String?> get(String key) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return maps.first['value'] as String?;
  }

  Future<void> set(String key, String value) async {
    final db = await LocalDatabase.database;
    await db.insert(
      _table,
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
