import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/notes_provider.dart';
import 'note_composer.dart';

/// شاشة الملاحظات الشخصية للعامل
///
/// - ملاحظات نصية أو صوتية
/// - محفوظة على الهاتف فقط (لا علاقة لها بالمزامنة)
class NotesScreen extends ConsumerStatefulWidget {
  const NotesScreen({super.key});

  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends ConsumerState<NotesScreen> {
  final AudioPlayer _player = AudioPlayer();
  String? _playingNoteId;
  StreamSubscription? _completeSub;

  @override
  void initState() {
    super.initState();
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingNoteId = null);
    });
  }

  @override
  void dispose() {
    _completeSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay(String id, String audioPath) async {
    try {
      if (_playingNoteId == id) {
        await _player.stop();
        if (mounted) setState(() => _playingNoteId = null);
      } else {
        await _player.play(DeviceFileSource(audioPath));
        if (mounted) setState(() => _playingNoteId = id);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر تشغيل التسجيل')),
        );
      }
    }
  }

  Future<void> _deleteNote(dynamic note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الملاحظة'),
        content: const Text('هل تريد حذف هذه الملاحظة نهائياً؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // حذف ملف الصوت إن وجد
    if (note.audioPath != null) {
      try {
        final f = File(note.audioPath as String);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }

    ref.read(notesProvider.notifier).delete(note);
  }

  void _openComposer() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const NoteComposer(key: ValueKey('composer')),    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(notesProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('ملاحظاتي')),
      floatingActionButton: state.notes.isEmpty
          ? null
          : FloatingActionButton.extended(
              heroTag: 'new_note',
              onPressed: _openComposer,
              icon: const Icon(Icons.add),
              label: const Text('جديدة'),
            ),
      body: state.isLoading && state.notes.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : state.notes.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.sticky_note_2_outlined,
                          size: 72, color: theme.colorScheme.outline),
                      const SizedBox(height: 12),
                      const Text('لا توجد ملاحظات بعد'),
                      const SizedBox(height: 6),
                      FilledButton.icon(
                        onPressed: _openComposer,
                        icon: const Icon(Icons.add),
                        label: const Text('أول ملاحظة'),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // تنبيه الخصوصية
                    Container(
                      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color:
                            theme.colorScheme.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.lock_outline,
                              size: 15,
                              color: theme.colorScheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'ملاحظاتك محفوظة على هذا الهاتف فقط',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: state.notes.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final note = state.notes[i];
                          final hasAudio = note.audioPath != null;
                          final isPlaying = _playingNoteId == note.id;

                          return Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        hasAudio
                                            ? Icons.mic_rounded
                                            : Icons.notes_rounded,
                                        size: 18,
                                        color: theme.colorScheme.primary,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _formatDate(note.createdAt),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: theme
                                                .colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        visualDensity:
                                            VisualDensity.compact,
                                        icon: Icon(Icons.delete_outline,
                                            size: 20,
                                            color:
                                                theme.colorScheme.error),
                                        onPressed: () => _deleteNote(note),
                                      ),
                                    ],
                                  ),
                                  if (note.content != null &&
                                      note.content!.isNotEmpty)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 8),
                                      child: SelectableText(
                                        note.content!,
                                        style:
                                            const TextStyle(fontSize: 15),
                                      ),
                                    ),
                                  if (hasAudio)
                                    Container(
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.primary
                                            .withValues(alpha: 0.08),
                                        borderRadius:
                                            BorderRadius.circular(12),
                                      ),
                                      child: ListTile(
                                        dense: true,
                                        leading: CircleAvatar(
                                          radius: 18,
                                          backgroundColor: theme
                                              .colorScheme.primary,
                                          child: Icon(
                                            isPlaying
                                                ? Icons.stop_rounded
                                                : Icons.play_arrow_rounded,
                                            color: Colors.white,
                                          ),
                                        ),
                                        title: Text(
                                          isPlaying
                                              ? 'جارٍ التشغيل...'
                                              : 'تسجيل صوتي',
                                          style: const TextStyle(
                                              fontSize: 14),
                                        ),
                                        onTap: () => _togglePlay(
                                            note.id, note.audioPath!),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }

  String _formatDate(DateTime d) {
    return '${d.day}/${d.month}/${d.year}  ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
