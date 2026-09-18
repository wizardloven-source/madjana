import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/auth/providers/auth_provider.dart';

/// بوابة شاشات المدير — تمنع وصول العامل حتى عبر التنقل المباشر (deep link).
class ManagerGate extends ConsumerWidget {
  const ManagerGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).currentUser;
    final allowed = user?.role.canViewFinancials ?? false;
    if (allowed) return child;
    return Scaffold(
      appBar: AppBar(title: const Text('غير مسموح')),
      body: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text(
              'هذه الشاشة متاحة للمدير فقط',
              style: TextStyle(fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}