import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:data/data.dart';
import '../../../core/providers.dart';

/// حالة شاشة الملاحظات
class NotesState {
  final List<WorkerNote> notes;
  final bool isLoading;

  const NotesState({this.notes = const [], this.isLoading = false});

  NotesState copyWith({List<WorkerNote>? notes, bool? isLoading}) =>
      NotesState(
        notes: notes ?? this.notes,
        isLoading: isLoading ?? this.isLoading,
      );
}

/// إدارة الملاحظات الشخصية للعامل
/// محلية بالكامل — لا تُزامن مع السحابة أبداً
class NotesNotifier extends StateNotifier<NotesState> {
  final NotesDao _dao;

  NotesNotifier(this._dao) : super(const NotesState()) {
    refresh();
  }

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true);
    final notes = await _dao.getAll();
    state = NotesState(notes: notes);
  }

  /// إضافة ملاحظة نصية (مع أو بدون تسجيل صوتي)
  Future<void> add({String? content, String? audioPath}) async {
    await _dao.add(content: content, audioPath: audioPath);
    await refresh();
  }

  /// حذف ملاحظة (المستدعي يحذف ملف الصوت من القرص)
  Future<void> delete(WorkerNote note) async {
    await _dao.delete(note.id);
    await refresh();
  }
}

final notesProvider =
    StateNotifierProvider<NotesNotifier, NotesState>((ref) {
  return NotesNotifier(ref.watch(notesDaoProvider));
});
