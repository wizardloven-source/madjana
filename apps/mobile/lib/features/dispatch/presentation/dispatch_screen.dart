import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/custom_numpad.dart';
import '../../../shared/widgets/date_picker_field.dart';
import '../../../shared/widgets/modern_ui.dart';
import '../../auth/providers/auth_provider.dart';
import '../../egg_production/providers/egg_production_provider.dart';
import '../../reference_data/providers/reference_data_provider.dart';
import '../providers/dispatch_provider.dart';

/// شاشة تخريج البيض (للبيع)
/// 
/// ⚠️ تحذير حاسم:
/// - لا يوجد أي حقل سعر أو مبلغ مالي
/// - العامل يُسجّل حركة البيض فقط
/// - إضافة زبون جديد عبر Dialog
class DispatchScreen extends ConsumerStatefulWidget {
  const DispatchScreen({super.key});

  @override
  ConsumerState<DispatchScreen> createState() => _DispatchScreenState();
}

class _DispatchScreenState extends ConsumerState<DispatchScreen> {
  DateTime _selectedDate = DateTime.now();
  String? _selectedCustomerId;
  int _cartons = 0;
  int _trays = 0;
  String _activeField = 'cartons';

  /// وزن الصحن (كغ) — يُدخل كنص لدعم المنازل العشرية
  String _trayWeightBuffer = '';

  final _notesController = TextEditingController();

  double? get _trayWeight {
    if (_trayWeightBuffer.isEmpty) return null;
    return double.tryParse(_trayWeightBuffer);
  }

  int get _totalEggs => EggCalculator.calculateTotal(
        cartons: _cartons,
        trays: _trays,
        looseEggs: 0,
      );

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  void _onNumpadKey(String key) {
    setState(() {
      // حقل وزن الصحن: يقبل المنازل العشرية (رقمان كحد أقصى)
      if (_activeField == 'trayWeight') {
        if (key == 'clear') {
          _trayWeightBuffer = '';
        } else if (key == 'backspace') {
          if (_trayWeightBuffer.isNotEmpty) {
            _trayWeightBuffer =
                _trayWeightBuffer.substring(0, _trayWeightBuffer.length - 1);
          }
        } else if (key == '.') {
          if (!_trayWeightBuffer.contains('.')) {
            _trayWeightBuffer = _trayWeightBuffer.isEmpty
                ? '0.'
                : '$_trayWeightBuffer.';
          }
        } else {
          final dotIndex = _trayWeightBuffer.indexOf('.');
          if (dotIndex == -1) {
            if (_trayWeightBuffer.length < 2) {
              _trayWeightBuffer += key;
            }
          } else if (_trayWeightBuffer.length - dotIndex - 1 < 2) {
            _trayWeightBuffer += key;
          }
        }
        return;
      }

      int currentValue = _activeField == 'cartons' ? _cartons : _trays;

      if (key == 'clear') {
        currentValue = 0;
      } else if (key == 'backspace') {
        currentValue = currentValue ~/ 10;
      } else {
        currentValue = currentValue * 10 + int.parse(key);
      }

      // التحويل التلقائي
      final normalized = EggCalculator.normalize(
        cartons: _activeField == 'cartons' ? currentValue : _cartons,
        trays: _activeField == 'trays' ? currentValue : _trays,
        looseEggs: 0,
      );

      _cartons = normalized.cartons;
      _trays = normalized.trays;
    });
  }

  Future<void> _addNewCustomer() async {
    final user = ref.read(authProvider).currentUser;
    final farmId = user?.farmId ?? '';

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => _NewCustomerDialog(),
    );

    if (result != null && mounted) {
      final newId = await ref
          .read(dispatchProvider.notifier)
          .addNewCustomer(
            farmId: farmId,
            name: result['name']!,
            phone: result['phone']!,
            notes: result['notes'],
          );

      if (newId != null) {
        // تحديث قائمة الزبائن
        ref.invalidate(customersProvider(farmId));
        setState(() => _selectedCustomerId = newId);
      }
    }
  }

  /// المخزون الحالي = إجمالي الإنتاج − إجمالي المخّرج (محلياً)
  Future<int> _currentStock(String farmId) async {
    final produced =
        await ref.read(eggProductionProvider.notifier).getRecords(farmId: farmId);
    final dispatched = await ref.read(dispatchProvider.notifier).getAll(farmId: farmId);

    int totalProduced = 0;
    for (final r in produced) {
      totalProduced += r.totalEggs;
    }

    int totalDispatched = 0;
    for (final d in dispatched) {
      totalDispatched += EggCalculator.calculateTotal(
        cartons: d.cartons,
        trays: d.trays,
        looseEggs: 0,
      );
    }

    return totalProduced - totalDispatched;
  }

  /// نافذة تجاوز المخزون: إرسال طلب للمدير أو إلغاء
  Future<bool?> _askManagerApproval({
    required int stock,
    required int requested,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warehouse_outlined,
            size: 40, color: Theme.of(ctx).colorScheme.error),
        title: const Text('الكمية تتجاوز المخزون'),
        content: Text(
          'المخزون الحالي: ${Formatters.formatNumber(stock)} بيضة\n'
          'الكمية المطلوبة: ${Formatters.formatNumber(requested)} بيضة\n\n'
          'هل تريد إرسال طلب إلى المدير للموافقة على التخريج؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.send_rounded, size: 18),
            label: const Text('إرسال طلب للمدير'),
          ),
        ],
      ),
    );
  }

  Future<void> _sendApprovalRequest({
    required String farmId,
    required int stock,
  }) async {
    try {
      await ref.read(supabaseClientProvider).from('dispatch_requests').insert({
        'farm_id': farmId,
        'customer_id': _selectedCustomerId,
        'cartons': _cartons,
        'trays': _trays,
        'total_eggs': _totalEggs,
        'stock_eggs': stock,
        'worker_id': ref.read(authProvider).currentUser?.uid,
      });
      if (!mounted) return;
      _showSuccess('تم إرسال الطلب إلى المدير بنجاح');
      setState(() {
        _cartons = 0;
        _trays = 0;
        _trayWeightBuffer = '';
        _notesController.clear();
      });
    } catch (_) {
      if (!mounted) return;
      AppSnack.error(context, 'تعذر إرسال الطلب، تحقق من الاتصال');
    }
  }

  Future<void> _save() async {
    if (_selectedCustomerId == null) {
      _showError('اختر الزبون');
      return;
    }
    if (_totalEggs == 0) {
      _showError('الكمية يجب أن تكون أكبر من صفر');
      return;
    }

    // تحقق منطقي من الوزن (صحن البيض عادة 1.5 - 2.5 كغ)
    if (_trayWeight != null && (_trayWeight! <= 0 || _trayWeight! > 10)) {
      _showError('وزن الصحن غير منطقي — أدخل وزناً بالكيلوغرام');
      return;
    }

    // ═══ التحقق من مخزون البيض قبل الحفظ ═══
    final user0 = ref.read(authProvider).currentUser!;
    final stock = await _currentStock(user0.farmId!);
    if (_totalEggs > stock) {
      final sendRequest = await _askManagerApproval(
        stock: stock,
        requested: _totalEggs,
      );
      if (sendRequest == true) {
        await _sendApprovalRequest(farmId: user0.farmId!, stock: stock);
      }
      return; // لا حفظ في الحالتين — يحتاج موافقة أو إلغاء
    }

    final user = ref.read(authProvider).currentUser!;
    final result = await ref.read(dispatchProvider.notifier).save(
          farmId: user.farmId!,
          date: _selectedDate,
          customerId: _selectedCustomerId!,
          cartons: _cartons,
          trays: _trays,
          trayWeightKg: _trayWeight,
          notes: _notesController.text.isEmpty ? null : _notesController.text,
          workerId: user.uid,
        );

    if (result.success) {
      _showSuccess('تم حفظ التخريج بنجاح');
      setState(() {
        _cartons = 0;
        _trays = 0;
        _trayWeightBuffer = '';
        _selectedCustomerId = null;
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
    final user = ref.watch(authProvider).currentUser;
    final farmId = user?.farmId ?? '';
    final customersAsync = ref.watch(customersProvider(farmId));
    final customers = customersAsync.value ?? const <CustomerModel>[];

    return Scaffold(
      appBar: AppBar(title: const Text('تخريج البيض')),
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

            // اختيار الزبون
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedCustomerId,
                    decoration: const InputDecoration(labelText: 'الزبون'),
                    items: customers.map((c) {
                      return DropdownMenuItem(
                        value: c.id,
                        child: Text(c.name),
                      );
                    }).toList(),
                    onChanged: (v) => setState(() => _selectedCustomerId = v),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: _addNewCustomer,
                    icon: const Icon(Icons.add),
                    label: const Text('جديد'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(AppConstants.colorSuccess),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // حقول الكمية
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

            // وزن الصحن (وزن 30 بيضة بالكيلوغرام)
            NumberTile(
              label: 'وزن الصحن كغ (اختياري)',
              value: _trayWeightBuffer.isEmpty
                  ? '—'
                  : '$_trayWeightBuffer كغ',
              active: _activeField == 'trayWeight',
              onTap: () => setState(() => _activeField = 'trayWeight'),
              hint: 'وزن 30 بيضة',
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
                children: [
                  const Text(
                    'الإجمالي:',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        Formatters.formatNumber(_totalEggs),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Color(AppConstants.colorInfo),
                        ),
                      ),
                      // متوسط وزن البيضة الواحدة
                      if (_trayWeight != null && _trayWeight! > 0)
                        Text(
                          '~${(_trayWeight! * 1000 / 30).toStringAsFixed(1)} غم/بيضة',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
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
            CustomNumpad(onKeyTap: _onNumpadKey, showDecimal: true),
            const SizedBox(height: 24),

            // زر الحفظ
            PrimaryActionButton(label: 'حفظ التخريج', onPressed: _save),

            // ⚠️ تنبيه: لا توجد أسعار
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'يتم تسجيل الكمية فقط. المدير هو من يحدد السعر ويقبض المبلغ.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNumberField({
    required String label,
    required int value,
    required String fieldKey,
  }) {
    return NumberTile(
      label: label,
      value: '$value',
      active: _activeField == fieldKey,
      onTap: () => setState(() => _activeField = fieldKey),
    );
  }
}

/// Dialog إضافة زبون جديد
class _NewCustomerDialog extends StatefulWidget {
  @override
  State<_NewCustomerDialog> createState() => _NewCustomerDialogState();
}

class _NewCustomerDialogState extends State<_NewCustomerDialog> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _notesController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_nameController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الاسم مطلوب')),
      );
      return;
    }
    if (_phoneController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الهاتف مطلوب')),
      );
      return;
    }

    Navigator.pop(context, {
      'name': _nameController.text,
      'phone': _phoneController.text,
      'notes': _notesController.text.isEmpty ? null : _notesController.text,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('زبون جديد'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'الاسم *'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneController,
              decoration: const InputDecoration(labelText: 'الهاتف *'),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notesController,
              decoration: const InputDecoration(labelText: 'ملاحظات'),
              maxLines: 2,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}