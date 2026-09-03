import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:core/core.dart';
import '../../../core/design_tokens.dart';
import '../../../shared/widgets/custom_numpad.dart';
import '../../../shared/widgets/date_picker_field.dart';
import '../../../shared/widgets/modern_ui.dart';
import '../../auth/providers/auth_provider.dart';
import '../../reference_data/providers/reference_data_provider.dart';
import '../providers/mortality_provider.dart';

/// شاشة إدخال النفوق
/// 
/// المميزات:
/// - رفع صورة من الكاميرا
/// - قائمة أسباب النفوق مع "أخرى"
/// - تحذير أحمر إذا تجاوز النفوق 1% من القطيع
class MortalityScreen extends ConsumerStatefulWidget {
  const MortalityScreen({super.key});

  @override
  ConsumerState<MortalityScreen> createState() => _MortalityScreenState();
}

class _MortalityScreenState extends ConsumerState<MortalityScreen> {
  DateTime _selectedDate = DateTime.now();
  String? _selectedFlockId;
  int _count = 0;
  MortalityReason? _selectedReason;
  File? _imageFile;
  String _activeField = 'count';

  final _otherController = TextEditingController();
  final _notesController = TextEditingController();

  // سجلات اليوم
  List<MortalityModel> _todayRecords = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTodayRecords());
  }

  Future<void> _loadTodayRecords() async {
    final user = ref.read(authProvider).currentUser;
    final farmId = user?.farmId ?? '';
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final records = await ref
        .read(mortalityProvider.notifier)
        .getRecords(farmId: farmId, fromDate: todayStart, toDate: now);
    if (mounted) setState(() => _todayRecords = records);
  }

  @override
  void dispose() {
    _otherController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _onNumpadKey(String key) {
    setState(() {
      if (key == 'clear') {
        _count = 0;
      } else if (key == 'backspace') {
        _count = _count ~/ 10;
      } else {
        _count = _count * 10 + int.parse(key);
      }
    });
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 70,
    );
    if (image != null) {
      setState(() => _imageFile = File(image.path));
    }
  }

  Future<void> _save() async {
    // التحقق من الحقول
    if (_selectedFlockId == null) {
      _showError('اختر القطيع');
      return;
    }
    if (_count <= 0) {
      _showError('عدد النافق يجب أن يكون أكبر من صفر');
      return;
    }
    if (_selectedReason == null) {
      _showError('اختر سبب النفوق');
      return;
    }
    if (_selectedReason == MortalityReason.other &&
        _otherController.text.isEmpty) {
      _showError('حدد السبب في حقل "أخرى"');
      return;
    }

    final user = ref.read(authProvider).currentUser;
    if (user == null || user.farmId == null) {
      _showError('خطأ في بيانات المستخدم');
      return;
    }
    final farmId = user.farmId!;

    final record = MortalityModel(
      farmId: farmId,
      flockId: _selectedFlockId!,
      date: _selectedDate,
      count: _count,
      reason: _selectedReason!,
      reasonOther: _selectedReason == MortalityReason.other
          ? _otherController.text
          : null,
      notes: _notesController.text.isEmpty ? null : _notesController.text,
      imageUrl: _imageFile?.path, // سيُرفع لاحقاً
      workerId: user.uid,
    );

    final result = await ref
        .read(mortalityProvider.notifier)
        .save(record, imageFile: _imageFile);

    if (result.success) {
      // تحذير النفوق المرتفع
      if (result.highMortalityWarning) {
        _showHighMortalityWarning(result.mortalityPercentage);
      } else {
        _showSuccess('تم الحفظ بنجاح');
      }
      _clearFields();
      _loadTodayRecords();
    } else {
      _showError(result.error ?? 'فشل الحفظ');
    }
  }

  void _showHighMortalityWarning(double percentage) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
        title: const Text('تنبيه مهم'),
        content: Text(
          'نسبة النفوق اليوم ${percentage.toStringAsFixed(2)}% أعلى من '
          'المستوى المعتاد.\nيرجى مراجعة الطبيب البيطري.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }

  void _clearFields() {
    setState(() {
      _count = 0;
      _selectedReason = null;
      _imageFile = null;
      _otherController.clear();
      _notesController.clear();
    });
  }

  void _showError(String message) => AppSnack.error(context, message);

  void _showSuccess(String message) => AppSnack.success(context, message);

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).currentUser;
    final farmId = user?.farmId ?? '';
    final flocksAsync = ref.watch(flocksProvider(farmId));
    final flocks = flocksAsync.value ?? const <FlockModel>[];

    return Scaffold(
      appBar: AppBar(title: const Text('إدخال النفوق')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // التاريخ
            DatePickerField(
              value: _selectedDate,
              label: 'التاريخ',
              onChanged: (date) => setState(() => _selectedDate = date),
            ),
            const SizedBox(height: 16),

            // اختيار القطيع
            DropdownButtonFormField<String>(
              initialValue: _selectedFlockId,
              decoration: const InputDecoration(labelText: 'القطيع'),
              items: flocks.map((flock) {
                return DropdownMenuItem(
                  value: flock.id,
                  child: Text(flock.displayName),
                );
              }).toList(),
              onChanged: (v) => setState(() => _selectedFlockId = v),
            ),
            const SizedBox(height: 16),

            // عدد النافق
            NumberTile(
              label: 'عدد النافق',
              value: '$_count',
              active: _activeField == 'count',
              onTap: () => setState(() => _activeField = 'count'),
            ),
            // تحليل لحظي قبل الحفظ: حجم القطيع + نسبة النفوق + الحالة
            if (flocks.isNotEmpty) ...[
              const SizedBox(height: 16),
              _MortalityFeedback(
                selectedFlockId: _selectedFlockId,
                currentCount: _count,
                flocks: flocks,
                todayRecords: _todayRecords,
              ),
            ],
            const SizedBox(height: 16),

            // سبب النفوق
            DropdownButtonFormField<MortalityReason>(
              initialValue: _selectedReason,
              decoration: const InputDecoration(labelText: 'سبب النفوق'),
              items: MortalityReason.values.map((reason) {
                return DropdownMenuItem(
                  value: reason,
                  child: Text(reason.label),
                );
              }).toList(),
              onChanged: (v) => setState(() => _selectedReason = v),
            ),
            const SizedBox(height: 16),

            // حقل "أخرى" يظهر عند اختيار "other"
            if (_selectedReason == MortalityReason.other)
              TextField(
                controller: _otherController,
                decoration: const InputDecoration(labelText: 'حدد السبب'),
                maxLines: 2,
              ),
            if (_selectedReason == MortalityReason.other)
              const SizedBox(height: 16),

            // ملاحظات
            TextField(
              controller: _notesController,
              decoration:
                  const InputDecoration(labelText: 'ملاحظات (اختياري)'),
              maxLines: 3,
            ),
            const SizedBox(height: 16),

            // زر التقاط صورة
            SizedBox(
              height: AppConstants.buttonMinHeight,
              child: OutlinedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.camera_alt),
                label: Text(
                  _imageFile == null ? 'التقاط صورة' : 'تم التقاط صورة ✓',
                ),
              ),
            ),
            const SizedBox(height: 16),

            // معاينة الصورة
            if (_imageFile != null)
              Container(
                height: 200,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(_imageFile!, fit: BoxFit.cover),
                ),
              ),
            const SizedBox(height: 24),

            // لوحة الأرقام
            CustomNumpad(onKeyTap: _onNumpadKey),
            const SizedBox(height: 24),

            // زر الحفظ
            PrimaryActionButton(
              label: 'حفظ',
              onPressed: _save,
              color: const Color(AppConstants.colorDanger),
            ),

            // سجلات اليوم
            if (_todayRecords.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Text('سجلات اليوم', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ..._todayRecords.map((record) {
                final danger = AppStatusColors.danger(context);
                return Dismissible(
                key: ValueKey(record.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(left: 20),
                  color: danger,
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                confirmDismiss: (direction) async {
                  return await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('حذف السجل'),
                      content: const Text('هل تريد حذف سجل النفوق؟'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: FilledButton.styleFrom(
                              backgroundColor:
                                  Theme.of(ctx).colorScheme.error),
                          child: const Text('حذف'),
                        ),
                      ],
                    ),
                  );
                },
                onDismissed: (direction) async {
                  if (record.id != null) {
                    await ref.read(mortalityProvider.notifier).deleteRecord(record.id!);
                    _loadTodayRecords();
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: danger.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: danger.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.pets, color: danger),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${Formatters.formatNumber(record.count)} طائر', style: const TextStyle(fontWeight: FontWeight.bold)),
                            Text('سبب: ${record.reason.label}${record.reasonOther != null ? ' (${record.reasonOther})' : ''}',
                                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
               );
              }),
            ],
          ],
        ),
      ),
    );
  }
}

/// تحليل لحظي قبل الحفظ: حجم القطيع + نسبة النفوق اليوم + حالة (طبيعي/مرتفع/حرج)
class _MortalityFeedback extends StatelessWidget {
  final String? selectedFlockId;
  final int currentCount;
  final List<FlockModel> flocks;
  final List<MortalityModel> todayRecords;

  const _MortalityFeedback({
    required this.selectedFlockId,
    required this.currentCount,
    required this.flocks,
    required this.todayRecords,
  });

  @override
  Widget build(BuildContext context) {
    if (selectedFlockId == null || currentCount <= 0) {
      return const SizedBox.shrink();
    }

    FlockModel? flock;
    for (final f in flocks) {
      if (f.id == selectedFlockId) {
        flock = f;
        break;
      }
    }
    if (flock == null || flock.currentCount <= 0) return const SizedBox.shrink();

    final existingToday = todayRecords
        .where((r) => r.flockId == selectedFlockId)
        .fold<int>(0, (sum, r) => sum + r.count);
    final totalToday = existingToday + currentCount;
    final percentage = (totalToday / flock.currentCount) * 100;

    // حالة بثلاث مستويات:
    //   ≤0.5% طبيعي، 0.5–1.0% مرتفع، >1.0% حرج
    final Color statusColor;
    final String statusLabel;
    IconData statusIcon;
    if (percentage > 1.0) {
      statusColor = AppStatusColors.danger(context);
      statusLabel = 'حرج';
      statusIcon = Icons.crisis_alert_rounded;
    } else if (percentage > 0.5) {
      statusColor = AppStatusColors.warning(context);
      statusLabel = 'مرتفع';
      statusIcon = Icons.warning_amber_rounded;
    } else {
      statusColor = AppStatusColors.success(context);
      statusLabel = 'ضمن الطبيعي';
      statusIcon = Icons.check_circle_rounded;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'القطيع: ${Formatters.formatNumber(flock.currentCount)} طائر',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  'نسبة النفوق اليوم: ${percentage.toStringAsFixed(2)}%',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: statusColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}