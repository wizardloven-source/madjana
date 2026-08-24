import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../providers/notes_provider.dart';

/// نافذة إنشاء ملاحظة جديدة (نص + تسجيل صوتي اختياري)
class NoteComposer extends ConsumerStatefulWidget {
  const NoteComposer({super.key});

  @override
  ConsumerState<NoteComposer> createState() => _NoteComposerState();
}

class _NoteComposerState extends ConsumerState<NoteComposer> {
  final _textController = TextEditingController();
  final _recorder = AudioRecorder();

  bool _isRecording = false;
  int _recordSeconds = 0;
  String? _recordedPath;
  Timer? _timer;
  bool _saving = false;

  @override
  void dispose() {
    _timer?.cancel();
    _textController.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggleRecord() async {
    if (_isRecording) {
      // إيقاف التسجيل
      final path = await _recorder.stop();
      _timer?.cancel();
      setState(() {
        _isRecording = false;
        if (path != null) _recordedPath = path;
      });
      return;
    }

    // طلب الصلاحية ثم بدء التسجيل
    if (!await _recorder.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('امنح صلاحية الميكروفون من إعدادات الهاتف أولاً')),
        );
      }
      return;
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final notesDir = Directory('${dir.path}/notes_audio');
      if (!await notesDir.exists()) {
        await notesDir.create(recursive: true);
      }
      final filePath =
          '${notesDir.path}/note_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: filePath,
      );
      setState(() {
        _isRecording = true;
        _recordedPath = null;
        _recordSeconds = 0;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordSeconds++);
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر بدء التسجيل')),
        );
      }
    }
  }

  /// حذف التسجيل غير المحفوظ
  Future<void> _discardRecording() async {
    final path = _recordedPath;
    setState(() => _recordedPath = null);
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<void> _save() async {
    final text = _textController.text.trim();
    final audio = _recordedPath;

    if (text.isEmpty && audio == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اكتب ملاحظة أو سجّل صوتاً أولاً')),
      );
      return;
    }

    setState(() => _saving = true);
    await ref.read(notesProvider.notifier).add(
          content: text.isEmpty ? null : text,
          audioPath: audio,
        );

    if (mounted) Navigator.pop(context);
  }

  String get _formattedDuration {
    final m = (_recordSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_recordSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // مقبض السحب
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'ملاحظة جديدة',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 14),

            // حقل النص
            TextField(
              controller: _textController,
              maxLines: 5,
              minLines: 3,
              autofocus: true,
              textInputAction: TextInputAction.newline,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'اكتب ملاحظتك هنا...',
                filled: true,
                fillColor:
                    theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 14),

            // قسم التسجيل الصوتي
            if (_recordedPath != null) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.check_circle,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text('تسجيل جاهز ($_recordedLabel)')),
                    IconButton(
                      icon: Icon(Icons.delete_outline,
                          size: 20, color: theme.colorScheme.error),
                      onPressed: _discardRecording,
                    ),
                  ],
                ),
              ),
            ] else
              Center(
                child: _isRecording
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // مؤشر التسجيل النابض
                          TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0.9, end: 1.15),
                            duration: const Duration(milliseconds: 600),
                            curve: Curves.easeInOut,
                            builder: (context, scale, child) =>
                                Transform.scale(
                                    scale: scale, child: child),
                            child: CircleAvatar(
                              radius: 26,
                              backgroundColor:
                                  theme.colorScheme.error,
                              child: const Icon(Icons.mic_rounded,
                                  color: Colors.white),
                            ),
                            onEnd: () =>
                                setState(() {}), // يعيد تشغيل الأنيميشن
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _formattedDuration,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ],
                      )
                    : OutlinedButton.icon(
                        onPressed: _toggleRecord,
                        icon: const Icon(Icons.mic_none_rounded),
                        label: const Text('تسجيل صوتي'),
                      ),
              ),

            // زر إيقاف التسجيل
            if (_isRecording) ...[
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: _toggleRecord,
                icon: const Icon(Icons.stop_rounded),
                label: const Text('إيقاف التسجيل'),
              ),
            ],

            const SizedBox(height: 18),

            // زر الحفظ
            FilledButton.icon(
              onPressed:
                  (_saving || (_textController.text.trim().isEmpty && _recordedPath == null))
                      ? null
                      : _save,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child:
                          CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_outlined),
              label: const Text('حفظ الملاحظة'),
            ),
          ],
        ),
      ),
    );
  }

  String get _recordedLabel {
    final m = (_recordSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_recordSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
