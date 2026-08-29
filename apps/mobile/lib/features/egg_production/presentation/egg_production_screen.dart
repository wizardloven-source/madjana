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

  // سجلات اليوم
  List<EggProductionModel> _todayRecords = [];

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
        .read(eggProductionProvider.notifier)
        .getRecords(farmId: farmId, fromDate: todayStart, toDate: now);
    if (mounted) setState(() => _todayRecords = records);
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

    final user = ref.read(authProvider).currentUser;
    if (user == null || user.farmId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('خطأ في بيانات المستخدم'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    final farmId = user.farmId!;

    final flocks = ref.read(flocksProvider(farmId)).value ??
        const <FlockModel>[];
    final flock =
        flocks.where((f) => f.id == _selectedFlockId).firstOrNull;
    final needsSection = (flock?.sectionsCount ?? 1) > 1;

    if (needsSection && _selectedSection == null) {
      _showError('اختر العنبر');
      return;
    }

    final record = EggProductionModel(
      farmId: farmId,
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
        _loadTodayRecords();
      }
    } else {
      _showError(result.error ?? 'فشل الحفظ');
    }
  }

  Future<void> _copyFromYesterday() async {
    final user = ref.read(authProvider).currentUser;
    if (user == null || user.farmId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('خطأ في بيانات المستخدم'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    final farmId = user.farmId!;

    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final record = await ref
        .read(eggProductionProvider.notifier)
        .getRecordByDate(farmId, yesterday);

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

            // سجلات اليوم
            if (_todayRecords.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Text('سجلات اليوم', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ..._todayRecords.map((record) => Dismissible(
                key: ValueKey(record.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(left: 20),
                  color: Colors.red,
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                confirmDismiss: (direction) async {
                  return await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('حذف السجل'),
                      content: const Text('هل تريد حذف سجل إنتاج البيض؟'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('حذف'),
                          style: FilledButton.styleFrom(backgroundColor: Colors.red),
                        ),
                      ],
                    ),
                  );
                },
                onDismissed: (direction) async {
                  if (record.id != null) {
                    await ref.read(eggProductionProvider.notifier).deleteRecord(record.id!);
                    _loadTodayRecords();
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.egg, color: Colors.blue),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${Formatters.formatNumber(record.totalEggs)} بيضة', style: const TextStyle(fontWeight: FontWeight.bold)),
                            Text('كراتين: ${record.cartons} | صحون: ${record.trays} | منفردة: ${record.looseEggs}',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              )),
            ],
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