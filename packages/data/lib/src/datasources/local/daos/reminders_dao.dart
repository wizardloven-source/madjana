import 'package:core/core.dart';
import '../local_database.dart';

/// مستودع تذكيرات العامل الخاصة (محلي فقط — لا يُزامَن أبداً)
class RemindersDao {
  static const _table = 'worker_reminders';

  Future<List<ReminderModel>> getAll() async {
    final db = await LocalDatabase.database;
    final maps = await db.query(_table, orderBy: 'created_at DESC');
    return maps.map(ReminderModel.fromMap).toList();
  }

  Future<void> add({required String title, String? body}) async {
    final db = await LocalDatabase.database;
    final reminder = ReminderModel(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title,
      body: (body == null || body.isEmpty) ? null : body,
      createdAt: DateTime.now(),
    );
    await db.insert(_table, reminder.toMap());
  }

  Future<void> delete(String id) async {
    final db = await LocalDatabase.database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }
}
