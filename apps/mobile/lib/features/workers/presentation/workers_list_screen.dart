// شاشة قائمة العمال للمدير
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../providers/worker_providers.dart';

class WorkersListScreen extends ConsumerWidget {
  const WorkersListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workersState = ref.watch(allWorkersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('إدارة العمال'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showAddWorkerDialog(context, ref),
          ),
        ],
      ),
      body: workersState.when(
        data: (workers) {
          if (workers.isEmpty) {
            return const Center(child: Text('لا يوجد عمال'));
          }
          return ListView.builder(
            itemCount: workers.length,
            itemBuilder: (context, index) {
              final worker = workers[index];
              return ListTile(
                title: Text(worker.name),
                subtitle: Text(worker.phone),
                trailing: Text('${worker.baseSalary}\$'),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(child: Text('خطأ: $error')),
      ),
    );
  }

  void _showAddWorkerDialog(BuildContext context, WidgetRef ref) {
    // TODO: Implement add worker dialog
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('ميزة إضافة عامل قيد التطوير')),
    );
  }
}
