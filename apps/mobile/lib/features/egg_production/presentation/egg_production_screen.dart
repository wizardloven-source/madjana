import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../shared/widgets/custom_numpad.dart';
import '../../../shared/widgets/date_picker_field.dart';
import '../../../shared/widgets/modern_ui.dart';
import '../../auth/providers/auth_provider.dart';
import '../../reference_data/providers/reference_data_provider.dart';
import '../providers/egg_production_provider.dart';

/// شاشة إدخال البيض
/// - Numpad مخصص
/// - تحويل تلقائي (صحون←كراتين، بيضات←صحون)
/// - حساب total_eggs في الوقت الفعلي
/// - زر "نسخ من أمس"
class EggProductionScreen extends ConsumerStatefulWidget {
  const EggProductionScreen({super.key});

  @override
  ConsumerState<EggProductionScreen> createState() => _EggProductionScreenState();
}

class _EggProductionScreenState extends ConsumerState<EggProductionScreen> {
  DateTime _selectedDate = DateTime.now();
  String? _selectedFlockId;
  int? _selectedSection;
  int _cartons = 0;
  int _trays = 0;
  int _looseEggs = 0;
  int _brokenEggs = 0;
  int _dirtyEggs = 0;
  double? _trayWeight;

  // الحقل النشط حالياً للـ Numpad
  String _activeField = 'cartons';

  int get _totalEggs => EggCalculator.calculateTotal(
        cartons: _cartons,
        trays: _trays,
        looseEggs: _looseEggs,
      );

  void _onNumpadKey(String key) {
    setState(() {
      int currentValue;
      switch (_activeField) {
        case 'cartons':
          currentValue = _cartons;
          break;
        case 'trays':
          currentValue = _trays;
          break;
        case 'loose':
          currentValue = _looseEggs;
          break;
        case 'broken':
          currentValue = _brokenEggs;
          break;
        case 'dirty':
          currentValue = _dirtyEggs;
          break;
        default:
          return;
      }

      if (key == 'clear') {
        currentValue = 0;
      } else if (key == 'backspace') {
        currentValue = currentValue ~/ 10;
      } else {
        currentValue = currentValue * 10 + int.parse(key);
      }

      // تطبيق التحويل التلقائي
      final normalized = EggCalculator.normalize(
        cartons: _activeField == 'cartons' ? currentValue : _cartons,
        trays: _activeField == 'trays' ? currentValue : _trays,
        looseEggs: _activeField == 'loose' ? currentValue : _looseEggs,
      );

      _cartons = normalized.cartons;
      _trays = normalized.trays;
      _looseEggs = normalized.looseEggs;

      switch (_activeField) {
        case 'broken':
          _brokenEggs = currentValue;
          break;
        case 'dirty':
          _dirtyEggs = currentValue;
          break;
      }
    });
  }

  Future<void> _save() async {
    if (_selectedFlockId == null) {
      _showError('اختر المدجنة');
      return;
    }
    if (_totalEggs == 0) {
      _showError('الإجمالي لا يمكن أن يكون صفراً');
      return;
    }

    final user = ref.read(authProvider).currentUser!;
    final flocks = ref.read(flocksProvider(user.farmId ?? '')).value ??
        const <FlockModel>[];
    final flock =
        flocks.where((f) => f.id == _selectedFlockId).firstOrNull;
    final needsSection = (flock?.sectionsCount ?? 1) > 1;

    if (needsSection && _selectedSection == null) {
      _showError('اختر العنبر');
      return;
    }

    final record = EggProductionModel(
      farmId: user.farmId!,
      flockId: _selectedFlockId!,
      date: _selectedDate,
      cartons: _cartons,
      trays: _trays,
      looseEggs: _looseEggs,
      brokenEggs: _brokenEggs,
      dirtyEggs: _dirtyEggs,
      trayWeightKg: _trayWeight,
      workerId: user.uid,
      sectionNo: needsSection ? _selectedSection : null,
    );

    final result = await ref
        .read(eggProductionProvider.notifier)
        .save(record);

    if (result.success) {
      if (mounted) {
        _showSuccess('تم الحفظ بنجاح');
        _clearFields();
      }
    } else {
      _showError(result.error ?? 'فشل الحفظ');
    }
  }

  Future<void> _copyFromYesterday() async {
    final user = ref.read(authProvider).currentUser!;
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final record = await ref
        .read(eggProductionProvider.notifier)
        .getRecordByDate(user.farmId!, yesterday);

    if (record != null) {
      setState(() {
        _cartons = record.cartons;
        _trays = record.trays;
        _looseEggs = record.looseEggs;
        _brokenEggs = record.brokenEggs;
        _dirtyEggs = record.dirtyEggs;
      });
    } else {
      _showError('لا توجد بيانات ليوم أمس');
    }
  }

  void _clearFields() {
    setState(() {
      _cartons = 0;
      _trays = 0;
      _looseEggs = 0;
      _brokenEggs = 0;
      _dirtyEggs = 0;
      _trayWeight = null;
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
      appBar: AppBar(title: const Text('إدخال البيض')),
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
              decoration: const InputDecoration(labelText: 'المدجنة / القطيع'),
              items: flocks.map((flock) {
                return DropdownMenuItem(
                  value: flock.id,
                  child: Text(flock.displayName),
                );
              }).toList(),
              onChanged: (v) => setState(() {
                _selectedFlockId = v;
                _selectedSection = null;
              }),
            ),
            const SizedBox(height: 16),

            // اختيار العنبر (يظهر إذا كانت المدجنة بها أكثر من عنبر)
            if (_selectedFlockId != null &&
                (flocks
                        .where((f) => f.id == _selectedFlockId)
                        .firstOrNull
                        ?.sectionsCount ??
                    1) >
                    1) ...[
              DropdownButtonFormField<int>(
                initialValue: _selectedSection,
                decoration:
                    const InputDecoration(labelText: 'العنبر *'),
                items: List.generate(
                  flocks
                          .where((f) => f.id == _selectedFlockId)
                          .firstOrNull!
                          .sectionsCount,
                  (i) => DropdownMenuItem(
                    value: i + 1,
                    child: Text('عنبر ${i + 1}'),
                  ),
                ),
                onChanged: (v) => setState(() => _selectedSection = v),
              ),
            ],
            const SizedBox(height: 24),

            // حقول الإدخال
            _buildNumberField(
              label: 'كراتين',
              value: _cartons,
              fieldKey: 'cartons',
            ),
            const SizedBox(height: 12),
            _buildNumberField(
              label: 'صحون (0-11)',
              value: _trays,
              fieldKey: 'trays',
            ),
            const SizedBox(height: 12),
            _buildNumberField(
              label: 'بيضات منفردة (0-29)',
              value: _looseEggs,
              fieldKey: 'loose',
            ),
            const SizedBox(height: 16),

            // الإجمالي
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(AppConstants.colorInfo).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'الإجمالي:',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    Formatters.formatNumber(_totalEggs),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Color(AppConstants.colorInfo),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            _buildNumberField(
              label: 'بيض مكسور',
              value: _brokenEggs,
              fieldKey: 'broken',
              optional: true,
            ),
            const SizedBox(height: 12),
            _buildNumberField(
              label: 'بيض أرضي',
              value: _dirtyEggs,
              fieldKey: 'dirty',
              optional: true,
            ),
            const SizedBox(height: 24),

            // لوحة الأرقام
            CustomNumpad(onKeyTap: _onNumpadKey),
            const SizedBox(height: 24),

            // أزرار الإجراءات
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _copyFromYesterday,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, AppConstants.buttonMinHeight),
                    ),
                    child: const Text('نسخ من أمس'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _clearFields,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, AppConstants.buttonMinHeight),
                    ),
                    child: const Text('مسح'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // زر الحفظ
            PrimaryActionButton(label: 'حفظ', onPressed: _save),
          ],
        ),
      ),
    );
  }

  Widget _buildNumberField({
    required String label,
    required int value,
    required String fieldKey,
    bool optional = false,
  }) {
    return NumberTile(
      label: label + (optional ? ' (اختياري)' : ''),
      value: '$value',
      active: _activeField == fieldKey,
      onTap: () => setState(() => _activeField = fieldKey),
    );
  }
}