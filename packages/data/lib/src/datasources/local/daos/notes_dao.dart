import '../local_database.dart';

/// ملاحظة شخصية للعامل (نصية أو صوتية)
///
/// تبقى على الهاتف فقط — لا تُزامن مع السحابة
class WorkerNote {
  final String id;
  final String? content;
  final String? audioPath;
  final DateTime createdAt;

  const WorkerNote({
    required this.id,
    this.content,
    this.audioPath,
    required this.createdAt,
  });

  bool get isAudioOnly => audioPath != null && (content == null || content!.isEmpty);

  factory WorkerNote.fromMap(Map<String, dynamic> map) {
    return WorkerNote(
      id: map['id'] as String,
      content: map['content'] as String?,
      audioPath: map['audio_path'] as String?,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// DAO لملاحظات العامل المحلية
class NotesDao {
  /// كل الملاحظات (الأحدث أولاً)
  Future<List<WorkerNote>> getAll() async {
    final db = await LocalDatabase.database;
    final rows = await db.query(
      'worker_notes',
      orderBy: 'created_at DESC',
    );
    return rows.map(WorkerNote.fromMap).toList();
  }

  /// إضافة ملاحظة نصية أو صوتية، يعيد المعرف
  Future<String> add({String? content, String? audioPath}) async {
    assert(content != null || audioPath != null);
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final db = await LocalDatabase.database;
    await db.insert('worker_notes', {
      'id': id,
      'content': content,
      'audio_path': audioPath,
      'created_at': DateTime.now().toIso8601String(),
    });
    return id;
  }

  /// حذف ملاحظة (المستدعي مسؤول عن حذف ملف الصوت من القرص)
  Future<void> delete(String id) async {
    final db = await LocalDatabase.database;
    await db.delete('worker_notes', where: 'id = ?', whereArgs: [id]);
  }
}
