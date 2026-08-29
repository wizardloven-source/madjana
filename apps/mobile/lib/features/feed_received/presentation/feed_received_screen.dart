import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../shared/widgets/custom_numpad.dart';
import '../../../shared/widgets/date_picker_field.dart';
import '../../../shared/widgets/modern_ui.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/feed_received_provider.dart';

/// شاشة استلام علف
/// 
/// المميزات:
/// - Toggle: أكياس / كيلو / طن
/// - تحويل تلقائي إلى كيلو
class FeedReceivedScreen extends ConsumerStatefulWidget {
  const FeedReceivedScreen({super.key});

  @override
  ConsumerState<FeedReceivedScreen> createState() => _FeedReceivedScreenState();
}

class _FeedReceivedScreenState extends ConsumerState<FeedReceivedScreen> {
  DateTime _selectedDate = DateTime.now();
  String? _selectedFarmId;
  FeedEntryMode _entryMode = FeedEntryMode.bags;
  double _quantity = 0;
  FeedType? _selectedFeedType;
  final _supplierController = TextEditingController();
  final _invoiceController = TextEditingController();
  final _notesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // تعيين المدجنة تلقائياً من المستخدم
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = ref.read(authProvider).currentUser;
      if (user?.farmId != null) {
        setState(() => _selectedFarmId = user!.farmId);
      }
    });
  }

  /// الكمية بالكيلو (محسوبة)
  double get _quantityKg {
    return switch (_entryMode) {
      FeedEntryMode.bags => _quantity * AppConstants.kgPerBag,
      FeedEntryMode.kg => _quantity,
      FeedEntryMode.ton => _quantity * AppConstants.kgPerTon,
    };
  }

  String _decimalBuffer = '';
  bool _hasDecimal = false;

  void _onNumpadKey(String key) {
    setState(() {
      if (key == 'clear') {
        _quantity = 0;
        _decimalBuffer = '';
        _hasDecimal = false;
      } else if (key == 'backspace') {
        if (_hasDecimal && _decimalBuffer.isNotEmpty) {
          _decimalBuffer = _decimalBuffer.substring(0, _decimalBuffer.length - 1);
          if (_decimalBuffer.isEmpty) {
            _hasDecimal = false;
            _quantity = _quantity.toInt().toDouble();
          } else {
            _quantity = double.tryParse('${_quantity.toInt()}.$_decimalBuffer') ?? _quantity.toInt().toDouble();
          }
        } else if (_quantity > 0) {
          final fullStr = _quantity.toInt().toString();
          if (fullStr.length > 1) {
            _quantity = double.parse(fullStr.substring(0, fullStr.length - 1));
          } else {
            _quantity = 0;
          }
        }
      } else if (key == '.') {
        if (_entryMode != FeedEntryMode.bags && !_hasDecimal) {
          _hasDecimal = true;
          _decimalBuffer = '';
        }
      } else {
        if (_hasDecimal) {
          if (_decimalBuffer.length < 2) {
            _decimalBuffer += key;
            _quantity = double.tryParse('${_quantity.toInt()}.$_decimalBuffer') ?? _quantity;
          }
        } else {
          _quantity = (_quantity.toInt() * 10 + int.parse(key)).toDouble();
        }
      }
    });
  }

  Future<void> _save() async {
    if (_selectedFarmId == null) {
      _showError('اختر المدجنة');
      return;
    }
    if (_quantity <= 0) {
      _showError('الكمية يجب أن تكون أكبر من صفر');
      return;
    }
    if (_selectedFeedType == null) {
      _showError('اختر نوع العلف');
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

    final result = await ref.read(feedReceivedProvider.notifier).save(
          farmId: farmId,
          date: _selectedDate,
          entryMode: _entryMode,
          quantity: _quantity,
          quantityKg: _quantityKg,
          feedType: _selectedFeedType!,
          supplier: _supplierController.text.isEmpty ? null : _supplierController.text,
          invoiceNumber: _invoiceController.text.isEmpty ? null : _invoiceController.text,
          notes: _notesController.text.isEmpty ? null : _notesController.text,
        );

    if (result.success) {
      _showSuccess('تم حفظ الاستلام بنجاح');
      setState(() {
        _quantity = 0;
        _selectedFeedType = null;
        _supplierController.clear();
        _invoiceController.clear();
        _notesController.clear();
      });
    } else {
      _showError(result.error ?? 'فشل الحفظ');
    }
  }

  void _showError(String message) => AppSnack.error(context, message);

  void _showSuccess(String message) => AppSnack.success(context, message);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('استلام علف')),
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

            // Toggle: أكياس / كيلو / طن
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: FeedEntryMode.values.map((mode) {
                  final label = switch (mode) {
                    FeedEntryMode.bags => 'أكياس',
                    FeedEntryMode.kg => 'كيلو',
                    FeedEntryMode.ton => 'طن',
                  };
                  return Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _entryMode = mode;
                        _quantity = 0;
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: _entryMode == mode
                              ? Colors.orange
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: _entryMode == mode ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 24),

            // الحقل الرئيسي
            NumberTile(
              label:
                  'الكمية (${switch (_entryMode) {
                    FeedEntryMode.bags => 'أكياس',
                    FeedEntryMode.kg => 'كغ',
                    FeedEntryMode.ton => 'طن',
                  }})',
              value: _entryMode == FeedEntryMode.bags
                  ? _quantity.toInt().toString()
                  : _quantity.toStringAsFixed(2),
              active: true,
              onTap: () {},
            ),
            const SizedBox(height: 16),

            // التحويل إلى كيلو
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'الإجمالي بالكيلو:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '${_quantityKg.toStringAsFixed(2)} كغ',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // نوع العلف
            DropdownButtonFormField<FeedType>(
              initialValue: _selectedFeedType,
              decoration: const InputDecoration(labelText: 'نوع العلف'),
              items: FeedType.values.map((type) {
                final label = switch (type) {
                  FeedType.starter => 'بادئ',
                  FeedType.grower => 'نامي',
                  FeedType.layer => 'بيّاض',
                  FeedType.main => 'علف رئيسي',
                };
                return DropdownMenuItem(value: type, child: Text(label));
              }).toList(),
              onChanged: (v) => setState(() => _selectedFeedType = v),
            ),
            const SizedBox(height: 16),

            // المورد
            TextField(
              controller: _supplierController,
              decoration:
                  const InputDecoration(labelText: 'اسم المورد (اختياري)'),
            ),
            const SizedBox(height: 16),

            // رقم الفاتورة
            TextField(
              controller: _invoiceController,
              decoration:
                  const InputDecoration(labelText: 'رقم الفاتورة (اختياري)'),
            ),
            const SizedBox(height: 16),

            // ملاحظات
            TextField(
              controller: _notesController,
              decoration:
                  const InputDecoration(labelText: 'ملاحظات (اختياري)'),
              maxLines: 2,
            ),
            const SizedBox(height: 24),

            // لوحة الأرقام
            CustomNumpad(
              onKeyTap: _onNumpadKey,
              showDecimal: _entryMode != FeedEntryMode.bags,
            ),
            const SizedBox(height: 24),

            // زر الحفظ
            PrimaryActionButton(
              label: 'حفظ',
              onPressed: _save,
              color: Colors.orange,
            ),
          ],
        ),
      ),
    );
  }
}