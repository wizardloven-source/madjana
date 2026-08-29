import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../shared/widgets/custom_numpad.dart';
import '../../../shared/widgets/date_picker_field.dart';
import '../../../shared/widgets/modern_ui.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/feed_consumption_provider.dart';

/// شاشة استهلاك العلف
/// 
/// المميزات:
/// - Toggle بين أكياس / كيلو
/// - حساب quantity_kg = bags × 24 تلقائياً
class FeedConsumptionScreen extends ConsumerStatefulWidget {
  const FeedConsumptionScreen({super.key});

  @override
  ConsumerState<FeedConsumptionScreen> createState() =>
      _FeedConsumptionScreenState();
}

class _FeedConsumptionScreenState extends ConsumerState<FeedConsumptionScreen> {
  DateTime _selectedDate = DateTime.now();
  String? _selectedFarmId;
  FeedEntryMode _entryMode = FeedEntryMode.bags;
  int _bagsCount = 0;
  double _quantityKg = 0;

  // سجلات اليوم
  List<FeedConsumptionModel> _todayRecords = [];

  @override
  void initState() {
    super.initState();
    // تعيين المدجنة تلقائياً من المستخدم
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = ref.read(authProvider).currentUser;
      if (user?.farmId != null) {
        setState(() => _selectedFarmId = user!.farmId);
      }
      _loadTodayRecords();
    });
  }

  Future<void> _loadTodayRecords() async {
    final user = ref.read(authProvider).currentUser;
    final farmId = user?.farmId ?? '';
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final records = await ref
        .read(feedConsumptionProvider.notifier)
        .getAll(farmId: farmId, fromDate: todayStart, toDate: now);
    if (mounted) setState(() => _todayRecords = records);
  }

  /// القيمة الحالية في الحقل النشط
  num get _currentValue =>
      _entryMode == FeedEntryMode.bags ? _bagsCount : _quantityKg;

  set _currentValue(num v) {
    if (_entryMode == FeedEntryMode.bags) {
      _bagsCount = v.toInt();
      _quantityKg = _bagsCount * AppConstants.kgPerBag;
    } else {
      _quantityKg = v.toDouble();
      _bagsCount = (_quantityKg / AppConstants.kgPerBag).round();
    }
  }

  void _onNumpadKey(String key) {
    setState(() {
      num currentValue = _currentValue;

      if (key == 'clear') {
        currentValue = 0;
      } else if (key == 'backspace') {
        currentValue = (currentValue ~/ 10);
      } else if (key == '.') {
        if (_entryMode == FeedEntryMode.kg && !currentValue.toString().contains('.')) {
          // السماح بالفاصلة العشرية في وضع الكيلو فقط
          currentValue = currentValue.toDouble();
        }
        return;
      } else {
        if (_entryMode == FeedEntryMode.bags) {
          currentValue = currentValue.toInt() * 10 + int.parse(key);
        } else {
          // للكيلو: نضيف الرقم بعد الفاصلة
          final str = currentValue.toString();
          if (str.contains('.')) {
            currentValue = double.parse('$str$key');
          } else {
            currentValue = currentValue.toInt() * 10 + int.parse(key);
          }
        }
      }

      _currentValue = currentValue;
    });
  }

  Future<void> _save() async {
    if (_selectedFarmId == null) {
      _showError('اختر المدجنة');
      return;
    }
    if (_currentValue <= 0) {
      _showError('الكمية يجب أن تكون أكبر من صفر');
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

    final record = FeedConsumptionModel(
      farmId: farmId,
      date: _selectedDate,
      entryMode: _entryMode,
      bagsCount: _bagsCount,
      quantityKg: _quantityKg,
      workerId: user.uid,
    );

    final result = await ref
        .read(feedConsumptionProvider.notifier)
        .save(record);

    if (result.success) {
      _showSuccess('تم الحفظ بنجاح');
      setState(() {
        _bagsCount = 0;
        _quantityKg = 0;
      });
      _loadTodayRecords();
    } else {
      _showError(result.error ?? 'فشل الحفظ');
    }
  }

  void _showError(String message) => AppSnack.error(context, message);

  void _showSuccess(String message) => AppSnack.success(context, message);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('استهلاك العلف')),
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

            // Toggle أكياس / كيلو
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _buildToggleButton(
                      label: 'أكياس',
                      isActive: _entryMode == FeedEntryMode.bags,
                      onTap: () => setState(() {
                        _entryMode = FeedEntryMode.bags;
                        _quantityKg = _bagsCount * AppConstants.kgPerBag;
                      }),
                    ),
                  ),
                  Expanded(
                    child: _buildToggleButton(
                      label: 'كيلو',
                      isActive: _entryMode == FeedEntryMode.kg,
                      onTap: () => setState(() {
                        _entryMode = FeedEntryMode.kg;
                        _bagsCount = (_quantityKg / AppConstants.kgPerBag).round();
                      }),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // الحقل النشط
            NumberTile(
              label: _entryMode == FeedEntryMode.bags
                  ? 'عدد الأكياس'
                  : 'الكمية (كغ)',
              value: _entryMode == FeedEntryMode.bags
                  ? '$_bagsCount'
                  : _quantityKg.toStringAsFixed(2),
              active: true,
              onTap: () {},
            ),
            const SizedBox(height: 16),

            // التحويل التلقائي
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  _buildConversionRow(
                    'عدد الأكياس',
                    '$_bagsCount كيس',
                  ),
                  const Divider(height: 24),
                  _buildConversionRow(
                    'الكمية بالكيلو',
                    '${_quantityKg.toStringAsFixed(2)} كغ',
                    isPrimary: true,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '(الكيس = ${AppConstants.kgPerBag.toInt()} كغ)',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // لوحة الأرقام
            CustomNumpad(
              onKeyTap: _onNumpadKey,
              showDecimal: _entryMode == FeedEntryMode.kg,
            ),
            const SizedBox(height: 24),

            // زر الحفظ
            SizedBox(
              height: AppConstants.buttonMinHeight,
              child: ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(AppConstants.colorWarning),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  'حفظ',
                  style: TextStyle(fontSize: 18, color: Colors.white),
                ),
              ),
            ),

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
                      content: const Text('هل تريد حذف سجل استهلاك العلف؟'),
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
                    await ref.read(feedConsumptionProvider.notifier).deleteRecord(record.id!);
                    _loadTodayRecords();
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.grain, color: Colors.orange),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(Formatters.formatWeight(record.quantityKg), style: const TextStyle(fontWeight: FontWeight.bold)),
                            Text('أكياس: ${record.bagsCount}', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
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

  Widget _buildToggleButton({
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isActive ? const Color(AppConstants.colorWarning) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isActive ? Colors.white : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConversionRow(String label, String value, {bool isPrimary = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: isPrimary ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: isPrimary ? 20 : 16,
            fontWeight: FontWeight.bold,
            color: isPrimary ? const Color(AppConstants.colorWarning) : null,
          ),
        ),
      ],
    );
  }
}