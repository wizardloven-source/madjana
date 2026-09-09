import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';

/// شاشة التهيئة الأولى: إنشاء حساب سوبر أدمن
/// (تظهر فقط عندما لا يوجد أي مستخدم في النظام بعد)
class BootstrapAdminScreen extends ConsumerStatefulWidget {
  /// عند وجود حساب سابق (مثلاً بروفايل محذوف بعد إعادة تطبيق المخطط)
  /// يسمح بالذهاب لشاشة تسجيل الدخول.
  final VoidCallback? onBackToLogin;

  const BootstrapAdminScreen({super.key, this.onBackToLogin});

  @override
  ConsumerState<BootstrapAdminScreen> createState() => _BootstrapAdminScreenState();
}

class _BootstrapAdminScreenState extends ConsumerState<BootstrapAdminScreen> {
  final _farmNameCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _managerNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _pinConfirmCtrl = TextEditingController();
  bool _obscurePin = true;

  @override
  void dispose() {
    _farmNameCtrl.dispose();
    _locationCtrl.dispose();
    _managerNameCtrl.dispose();
    _phoneCtrl.dispose();
    _pinCtrl.dispose();
    _pinConfirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final farmName = _farmNameCtrl.text.trim();
    final location = _locationCtrl.text.trim();
    final managerName = _managerNameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final pin = _pinCtrl.text.trim();
    final pinConfirm = _pinConfirmCtrl.text.trim();

    if (farmName.isEmpty) {
      _showError('أدخل اسم المزرعة');
      return;
    }
    if (managerName.isEmpty) {
      _showError('أدخل اسم المسؤول');
      return;
    }
    if (phone.isEmpty) {
      _showError('أدخل رقم الهاتف');
      return;
    }
    if (pin.length != 4 || int.tryParse(pin) == null) {
      _showError('الرمز السري يجب أن يكون 4 أرقام');
      return;
    }
    if (pin != pinConfirm) {
      _showError('الرمزان غير متطابقين');
      return;
    }

    final result = await ref.read(authProvider.notifier).createFirstAdmin(
          farmName: farmName,
          location: location,
          managerName: managerName,
          phone: phone,
          pin: pin,
        );

    if (!result.success && mounted) {
      _showError(result.error ?? 'فشل إنشاء الحساب');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(authProvider.select((s) => s.isLoading));

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.admin_panel_settings,
                      size: 64,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'تهيئة النظام لأول مرة',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'لم يتم العثور على حساب سوبر أدمن.\nأنشئ الحساب الأول لتصبح مسؤول النظام.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _farmNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'اسم المزرعة',
                        prefixIcon: Icon(Icons.home_work_outlined),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _locationCtrl,
                      decoration: const InputDecoration(
                        labelText: 'الموقع (اختياري)',
                        prefixIcon: Icon(Icons.location_on_outlined),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _managerNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'اسم المسؤول',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                        labelText: 'رقم الهاتف',
                        prefixIcon: Icon(Icons.phone),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _pinCtrl,
                      obscureText: _obscurePin,
                      keyboardType: TextInputType.number,
                      textDirection: TextDirection.ltr,
                      maxLength: 4,
                      decoration: InputDecoration(
                        labelText: 'الرمز السري (4 أرقام)',
                        prefixIcon: const Icon(Icons.lock_outline),
                        counterText: '',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePin
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () =>
                              setState(() => _obscurePin = !_obscurePin),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _pinConfirmCtrl,
                      obscureText: _obscurePin,
                      keyboardType: TextInputType.number,
                      textDirection: TextDirection.ltr,
                      maxLength: 4,
                      decoration: const InputDecoration(
                        labelText: 'تأكيد الرمز السري',
                        prefixIcon: Icon(Icons.lock_reset),
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 32),
                    FilledButton(
                      onPressed: isLoading ? null : _create,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: isLoading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('إنشاء حساب سوبر أدمن'),
                    ),
                    if (widget.onBackToLogin != null) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed:
                            isLoading ? null : widget.onBackToLogin,
                        child: const Text('لديك حساب مسبق؟ سجّل الدخول'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}