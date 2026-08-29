import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../shared/widgets/custom_numpad.dart';
import '../../../shared/widgets/date_picker_field.dart';
import '../../../shared/widgets/modern_ui.dart';
import '../../auth/providers/auth_provider.dart';
import '../../reference_data/providers/reference_data_provider.dart';
import '../../dispatch/providers/dispatch_provider.dart';
import '../../../core/providers.dart';

/// شاشة قبض المبالغ - للمدير فقط
///
/// ⚠️ لا يمكن للعامل الوصول لهذه الشاشة أبداً
class PaymentsScreen extends ConsumerStatefulWidget {
  const PaymentsScreen({super.key});

  @override
  ConsumerState<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends ConsumerState<PaymentsScreen> {
  DateTime _selectedDate = DateTime.now();
  String? _selectedCustomerId;
  String? _selectedDispatchId;
  double _pricePerCarton = 0;
  double _amountPaid = 0;
  PaymentMethod _paymentMethod = PaymentMethod.cash;
  String _activeField = 'price';

  final _notesController = TextEditingController();

  // قائمة التخريج المتاحة (غير المدفوعة)
  final List<DispatchModel> _dispatches = [];
  bool _dispatchesLoaded = false;

  // مخازن الإدخال النصي لكل حقل (تمنع أخطاء التحويل العشري)
  final Map<String, String> _buffers = {
    'price': '',
    'amount': '',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDispatches();
    });
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadDispatches() async {
    final user = ref.read(authProvider).currentUser;
    final farmId = user?.farmId ?? '';
    if (farmId.isEmpty || _dispatchesLoaded) return;
    _dispatchesLoaded = true;

    final all = await ref.read(dispatchProvider.notifier).getAll(farmId: farmId);
    if (!mounted) return;
    setState(() {
      _dispatches.clear();
      _dispatches.addAll(all.where((d) => d.paymentStatus != PaymentStatus.paid));
    });
  }

  void _onNumpadKey(String key) {
    setState(() {
      var buf = _buffers[_activeField] ?? '';

      switch (key) {
        case 'clear':
          buf = '';
          break;
        case 'backspace':
          buf = buf.isEmpty ? '' : buf.substring(0, buf.length - 1);
          break;
        case '.':
          if (!buf.contains('.')) buf = buf.isEmpty ? '0.' : '$buf.';
          break;
        default:
          final dotIndex = buf.indexOf('.');
          final decimalDigits =
              dotIndex == -1 ? 0 : buf.length - dotIndex - 1;
          if (decimalDigits < 2) buf += key;
      }

      _buffers[_activeField] = buf;
      _pricePerCarton = double.tryParse(_buffers['price']!) ?? 0;
      _amountPaid = double.tryParse(_buffers['amount']!) ?? 0;
    });
  }

  double get _totalDue {
    if (_selectedDispatchId == null) return 0;
    final dispatch = _dispatches.where((d) => d.id == _selectedDispatchId).firstOrNull;
    if (dispatch == null) return 0;
    return _pricePerCarton * (dispatch.cartons + dispatch.trays / AppConstants.traysPerCarton);
  }

  Future<void> _save() async {
    final user = ref.read(authProvider).currentUser;
    if (user == null) return;
    if (_selectedCustomerId == null) {
      _showError('اختر الزبون');
      return;
    }
    if (_selectedDispatchId == null) {
      _showError('اختر الفاتورة');
      return;
    }
    if (_pricePerCarton <= 0) {
      _showError('أدخل سعر الكرتون');
      return;
    }
    if (_amountPaid <= 0) {
      _showError('أدخل المبلغ المقبوض');
      return;
    }

    try {
      final payment = PaymentModel(
        farmId: user.farmId ?? '',
        dispatchId: _selectedDispatchId,
        customerId: _selectedCustomerId!,
        date: _selectedDate,
        pricePerCarton: _pricePerCarton,
        totalDue: _totalDue,
        amountPaid: _amountPaid,
        paymentMethod: _paymentMethod,
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        managerId: user.uid,
      );

      await ref.read(paymentRepositoryProvider).save(payment);

      if (!mounted) return;
      _showSuccess('تم تسجيل القبض بنجاح');
      setState(() {
        _buffers['price'] = '';
        _buffers['amount'] = '';
        _pricePerCarton = 0;
        _amountPaid = 0;
        _selectedDispatchId = null;
        _notesController.clear();
      });
      // إعادة تحميل الفواتير لتحديث حالة الدفع
      _dispatchesLoaded = false;
      _loadDispatches();
    } catch (e) {
      if (!mounted) return;
      _showError('حدث خطأ أثناء الحفظ');
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
      appBar: AppBar(title: const Text('قبض المبالغ')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DatePickerField(
              value: _selectedDate,
              label: 'التاريخ',
              onChanged: (date) => setState(() => _selectedDate = date),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _selectedCustomerId,
              decoration: const InputDecoration(labelText: 'الزبون'),
              items: customers.map((c) {
                return DropdownMenuItem(value: c.id, child: Text(c.name));
              }).toList(),
              onChanged: (v) => setState(() => _selectedCustomerId = v),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _selectedDispatchId,
              decoration: const InputDecoration(labelText: 'الفاتورة'),
              items: _dispatches.map((d) {
                return DropdownMenuItem(
                  value: d.id,
                  child: Text(
                    '${Formatters.formatDate(d.date)} - ${Formatters.formatNumber(d.cartons)} كرتون',
                  ),
                );
              }).toList(),
              onChanged: (v) => setState(() => _selectedDispatchId = v),
            ),
            const SizedBox(height: 24),
            _buildMoneyField('سعر الكرتون', 'price'),
            const SizedBox(height: 12),
            _buildMoneyField('المبلغ المقبوض', 'amount'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(AppConstants.colorSuccess).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('الإجمالي المستحق:', style: TextStyle(fontSize: 16)),
                  Text(
                    Formatters.formatCurrency(_totalDue),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Color(AppConstants.colorSuccess),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<PaymentMethod>(
              initialValue: _paymentMethod,
              decoration: const InputDecoration(labelText: 'طريقة الدفع'),
              items: PaymentMethod.values.map((m) {
                final label = switch (m) {
                  PaymentMethod.cash => 'نقداً',
                  PaymentMethod.transfer => 'تحويل بنكي',
                  PaymentMethod.check => 'شيك',
                  PaymentMethod.credit => 'آجل',
                };
                return DropdownMenuItem(value: m, child: Text(label));
              }).toList(),
              onChanged: (v) => setState(() => _paymentMethod = v ?? PaymentMethod.cash),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _notesController,
              decoration: const InputDecoration(labelText: 'ملاحظات (اختياري)'),
              maxLines: 2,
            ),
            const SizedBox(height: 24),
            CustomNumpad(onKeyTap: _onNumpadKey, showDecimal: true),
            const SizedBox(height: 24),
            PrimaryActionButton(label: 'حفظ القبض', onPressed: _save),
          ],
        ),
      ),
    );
  }

  Widget _buildMoneyField(String label, String fieldKey) {
    final buf = _buffers[fieldKey] ?? '';
    return NumberTile(
      label: label,
      value: buf.isEmpty ? '0' : buf,
      active: _activeField == fieldKey,
      onTap: () => setState(() => _activeField = fieldKey),
    );
  }
}
