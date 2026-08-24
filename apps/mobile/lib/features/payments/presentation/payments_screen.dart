import 'package:flutter/material.dart';
import 'package:core/core.dart';

/// شاشة القبض (للمدير فقط)
/// 
/// ملاحظات:
/// - هذه الشاشة تظهر فقط للمدير في تطبيق سطح المكتب
/// - العامل لا يراها أبداً (تمنع على مستوى التطبيق والـ RLS)
/// - تُستخدم لتسجيل الأسعار والقبض من الزبائن
class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _buffers = <String, String>{
    'price': '',
    'amount': '',
  };
  int? _selectedDispatchId;
  double _pricePerCarton = 0;
  double _amountPaid = 0;
  double _totalDue = 0;

  // قائمة التخريجات غير المقبوضة (يجلبها من PaymentRepository)
  final List<Map<String, dynamic>> _dispatches = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تسجيل القبض')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              // اختيار التخريدة
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'اختر التخريدة',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<int?>(
                        value: _selectedDispatchId,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: 'اختر التخريدة',
                        ),
                        items: _dispatches
                            .map((d) => DropdownMenuItem(
                                  value: d['id'] as int?,
                                  label: Text(
                                    'تخريدة ${d['date']} - ${d['cartons']} كرتون',
                                  ),
                                ))
                            .toList(),
                        onChanged: (v) {
                          setState(() => _selectedDispatchId = v);
                          _calculateTotal();
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // سعر الكرتون
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'سعر الكرتون',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: _buffers['price'],
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: 'أدخل سعر الكرتون',
                          suffixText: 'د.ع',
                        ),
                        onChanged: (v) {
                          setState(() {
                            _buffers['price'] = v;
                            _pricePerCarton = double.tryParse(v) ?? 0;
                            _calculateTotal();
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // الإجمالي
              if (_totalDue > 0)
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'الإجمالي المستحق:',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${_totalDue.toStringAsFixed(0)} د.ع',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Color(AppConstants.colorSuccess),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),

              // المبلغ المقبوض
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'المبلغ المقبوض',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: _buffers['amount'],
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: 'أدخل المبلغ المقبوض',
                          suffixText: 'د.ع',
                        ),
                        onChanged: (v) {
                          setState(() {
                            _buffers['amount'] = v;
                            _amountPaid = double.tryParse(v) ?? 0;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // زر الحفظ
              SizedBox(
                height: AppConstants.buttonMinHeight,
                child: ElevatedButton.icon(
                  onPressed: _savePayment,
                  icon: const Icon(Icons.save),
                  label: const Text('حفظ الدفع'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(AppConstants.colorSuccess),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // تنبيه أمني
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber, color: Colors.orange),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '⚠️ ميزة تسجيل القبض قيد التطوير. سيتم ربطها بـ PaymentRepository قريباً.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _calculateTotal() {
    if (_selectedDispatchId == null || _pricePerCarton <= 0) {
      setState(() => _totalDue = 0);
      return;
    }
    final dispatch = _dispatches.firstWhere(
      (d) => d['id'] == _selectedDispatchId,
      orElse: () => {'cartons': 0},
    );
    final cartons = dispatch['cartons'] as int? ?? 0;
    setState(() => _totalDue = cartons * _pricePerCarton);
  }

  void _savePayment() {
    if (_selectedDispatchId == null) {
      _showError('اختر تخريدة أولاً');
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

    // TODO: حفظ الدفع عبر PaymentRepository (يُكمل مع الويب)
    // مثال:
    // await ref.read(paymentProvider.notifier).createPayment(
    //   dispatchId: _selectedDispatchId!,
    //   pricePerCarton: _pricePerCarton,
    //   amountPaid: _amountPaid,
    // );
    
    _showSuccess('تم تسجيل القبض بنجاح (مؤقتاً)');
    setState(() {
      _buffers['price'] = '';
      _buffers['amount'] = '';
      _pricePerCarton = 0;
      _amountPaid = 0;
      _totalDue = 0;
      _selectedDispatchId = null;
    });
  }

  void _showError(String message) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.red),
  );

  void _showSuccess(String message) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.green),
  );
}
