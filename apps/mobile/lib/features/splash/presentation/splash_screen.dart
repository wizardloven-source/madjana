import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:core/core.dart';

/// شاشة السبلاش — تُعرض ~6 ثوانٍ قبل الشاشة الرئيسية.
///
/// تعرض صورة السبلاش + نص تحفيزي عشوائي واحداً من [splashTips] + مؤشر
/// تحميل. عند انتهاء المدة يُستدعى [onFinished] ليُحوِّل التطبيق للشاشة
/// الرئيسية (عبر Navigator أو setState حسب المُضيف).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.onFinished});

  /// يُستدعى بعد ~6 ثوانٍ لإنهاء السبلاش والانتقال للشاشة الرئيسية.
  final VoidCallback? onFinished;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  late final String _tip;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _tip = splashTips[Random().nextInt(splashTips.length)];
    _timer = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      widget.onFinished?.call();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // خلفية داكنة تنسجم مع صورة السبلاش (ديك ذهبي على خلفية سوداء): حواف
      // الصورة ≈ (1,1,1) فتندمج مع الخلفية بلا إطار مرئي.
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // الصورة مباشرة على الخلفية الداكنة — بلا إطار/زاوية بيضاء.
              Image.asset(
                'assets/yaseen_farm splash.jpg',
                width: 300,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 32),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _tip,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFD4AF37),
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    height: 1.8,
                  ),
                ),
              ),
              const SizedBox(height: 40),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFFD4AF37),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
