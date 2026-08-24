import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:core/core.dart';
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

    final user = ref.read(authProvider).currentUser!;
    final record = MortalityModel(
      farmId: user.farmId!,
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
    } else {
      _showError(result.error ?? 'فشل الحفظ');
    }
  }

  void _showHighMortalityWarning(double percentage) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(AppConstants.colorDanger),
        title: const Row(
          children: [
            Icon(Icons.warning, color: Colors.white),
            SizedBox(width: 8),
            Text('تنبيه! نفوق مرتفع', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Text(
          'نسبة النفوق ${percentage.toStringAsFixed(2)}% من القطيع.\n'
          'يرجى مراجعة الطبيب البيطري فوراً.',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('حسناً', style: TextStyle(color: Colors.white)),
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
          ],
        ),
      ),
    );
  }
}