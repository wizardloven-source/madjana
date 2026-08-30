import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// شاشة مراقبة وحل تعارضات المزامنة
/// متاحة فقط للمديرين
class ConflictMonitorScreen extends ConsumerStatefulWidget {
  const ConflictMonitorScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<ConflictMonitorScreen> createState() => _ConflictMonitorScreenState();
}

class _ConflictMonitorScreenState extends ConsumerState<ConflictMonitorScreen> {
  bool _isLoading = true;
  List<dynamic> _conflicts = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadConflicts();
  }

  Future<void> _loadConflicts() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    // TODO: استدعاء UseCase الحقيقي بعد إعداد Dependency Injection
    await Future.delayed(const Duration(seconds: 1)); // محاكاة
    
    setState(() {
      _conflicts = []; // سيتم ملؤها لاحقاً
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('مراقبة التعارضات')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text('حدث خطأ: $_error'),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadConflicts,
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('التعارضات'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadConflicts,
          ),
        ],
      ),
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.settings_suggest, size: 64, color: Colors.blue),
            SizedBox(height: 16),
            Text(
              'شاشة مراقبة التعارضات جاهزة',
              style: TextStyle(fontSize: 18),
            ),
            SizedBox(height: 8),
            Text(
              'سيتم ربطها بـ UseCases قريباً',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
