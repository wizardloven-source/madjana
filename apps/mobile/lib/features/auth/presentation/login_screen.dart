import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../shared/widgets/custom_numpad.dart';
import '../providers/auth_provider.dart';

/// شاشة تسجيل الدخول
/// - رقم الهاتف + PIN من 4 أرقام مع إرسال تلقائي عند الاكتمال
/// - رسائل خطأ داخلية بدل التنبيهات المنبثقة
/// - تذكر رقم الهاتف آخر جلسة ناجحة
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  static const String _phoneKey = 'last_login_phone';

  final _phoneController = TextEditingController();
  final _phoneFocus = FocusNode();
  String _pin = '';
  bool _rememberMe = true;
  bool _isLoading = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // استرجاع آخر رقم هاتف نجح به الدخول
      final prefs = await SharedPreferences.getInstance();
      final savedPhone = prefs.getString(_phoneKey);
      if (mounted && savedPhone != null && savedPhone.isNotEmpty) {
        setState(() => _phoneController.text = savedPhone);
      }
    });
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _phoneFocus.dispose();
    super.dispose();
  }

  void _onNumpadKey(String key) {
    HapticFeedback.lightImpact();
    setState(() {
      _errorText = null;
      if (key == 'clear') {
        _pin = '';
      } else if (key == 'backspace') {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
      } else if (_pin.length < AppConstants.maxPinLength) {
        _pin += key;
      }
    });
    // إرسال تلقائي عند اكتمال الرمز
    if (_pin.length == AppConstants.maxPinLength) {
      _login();
    }
  }

  Future<void> _login() async {
    if (_isLoading) return;
    if (!mounted) return;
    FocusScope.of(context).unfocus();

    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      setState(() => _errorText = 'أدخل رقم الهاتف أولاً');
      return;
    }
    if (_pin.length != AppConstants.maxPinLength) {
      setState(() => _errorText =
          'الرمز يجب أن يكون ${AppConstants.maxPinLength} أرقام');
      HapticFeedback.heavyImpact();
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final result = await ref.read(authProvider.notifier).login(
            phone: phone,
            pin: _pin,
            rememberMe: _rememberMe,
          );

      if (!mounted) return;

      if (result.success) {
        // حفظ رقم الهاتف للجلسات القادمة
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_phoneKey, phone);
        } catch (_) {}
        // _RootGate سيُحوّل تلقائياً للرئيسية عند تغيير الحالة
      } else {
        HapticFeedback.heavyImpact();
        setState(() {
          _errorText = result.error ?? 'فشل تسجيل الدخول';
          _pin = '';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorText = 'خطأ غير متوقع: $e';
          _pin = '';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [const Color(0xFF0D1B2A), const Color(0xFF121212)]
                : [Colors.blue.shade50, Colors.white],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    const SizedBox(height: 16),

                    // الشعار والعنوان
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.primary
                            .withValues(alpha: 0.12),
                      ),
                      child: Icon(
                        Icons.egg,
                        size: 56,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'نظام إدارة المداجن',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'سجّل الدخول للمتابعة',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // بطاقة الدخول
                    Card(
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // حقل رقم الهاتف
                            TextField(
                              controller: _phoneController,
                              focusNode: _phoneFocus,
                              keyboardType: TextInputType.phone,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 22),
                              onChanged: (_) =>
                                  setState(() => _errorText = null),
                              decoration: InputDecoration(
                                labelText: 'رقم الهاتف',
                                prefixIcon: const Icon(Icons.phone),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),

                            // نقاط رمز الدخول
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: List.generate(
                                AppConstants.maxPinLength,
                                (i) => AnimatedContainer(
                                  duration:
                                      const Duration(milliseconds: 150),
                                  width: 36,
                                  height: 36,
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 8),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: i < _pin.length
                                        ? theme.colorScheme.primary
                                        : Colors.transparent,
                                    border: Border.all(
                                      color: i < _pin.length
                                          ? theme.colorScheme.primary
                                          : theme.colorScheme.outline,
                                      width: 2,
                                    ),
                                  ),
                                  child: i < _pin.length
                                      ? const Icon(Icons.check,
                                          size: 18, color: Colors.white)
                                      : null,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),

                            // رسالة الخطأ الداخلية
                            AnimatedSize(
                              duration: const Duration(milliseconds: 200),
                              child: _errorText != null
                                  ? Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.error_outline,
                                          size: 16,
                                          color: theme.colorScheme.error,
                                        ),
                                        const SizedBox(width: 6),
                                        Flexible(
                                          child: Text(
                                            _errorText!,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 13,
                                              color:
                                                  theme.colorScheme.error,
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : const SizedBox(height: 18),
                            ),

                            // تذكرني
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Switch(
                                  value: _rememberMe,
                                  onChanged: (v) =>
                                      setState(() => _rememberMe = v),
                                ),
                                const Text('تذكرني على هذا الجهاز'),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // لوحة الأرقام
                    CustomNumpad(onKeyTap: _onNumpadKey),
                    const SizedBox(height: 20),

                    // زر تسجيل الدخول
                    SizedBox(
                      width: double.infinity,
                      height: AppConstants.buttonMinHeight,
                      child: ElevatedButton.icon(
                        onPressed: _isLoading ? null : _login,
                        icon: _isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.login),
                        label: Text(
                          _isLoading ? 'جارٍ التحقق...' : 'دخول',
                          style: const TextStyle(fontSize: 18),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
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
