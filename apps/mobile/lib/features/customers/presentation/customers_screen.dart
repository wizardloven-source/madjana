import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/providers/auth_provider.dart';
import '../../reference_data/providers/reference_data_provider.dart';
import '../../dispatch/providers/dispatch_provider.dart';

/// شاشة إدارة الزبائن من الموبايل
class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});
  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  String? _selectedFarmId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = ref.read(authProvider).currentUser;
      if (user?.farmId != null) setState(() => _selectedFarmId = user!.farmId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final farmId = _selectedFarmId ?? '';
    final customersAsync = ref.watch(customersProvider(farmId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('الزبائن'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showAddDialog(context, ref),
          ),
        ],
      ),
      body: customersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('خطأ: $e')),
        data: (customers) {
          if (customers.isEmpty) {
            return const Center(child: Text('لا يوجد زبائن'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: customers.length,
            itemBuilder: (context, index) {
              final c = customers[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: CircleAvatar(
                    child: Text(c.name.isNotEmpty ? c.name[0] : '?'),
                  ),
                  title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(c.phone),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showAddDialog(BuildContext context, WidgetRef ref) {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final notesCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة زبون جديد'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'الاسم')),
              const SizedBox(height: 12),
              TextField(controller: phoneCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف')),
              const SizedBox(height: 12),
              TextField(controller: notesCtrl, decoration: const InputDecoration(labelText: 'ملاحظات'), maxLines: 2),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () async {
              if (nameCtrl.text.isEmpty || phoneCtrl.text.isEmpty) return;
              final result = await ref.read(dispatchProvider.notifier).addNewCustomer(
                farmId: _selectedFarmId ?? '',
                name: nameCtrl.text,
                phone: phoneCtrl.text,
                notes: notesCtrl.text.isEmpty ? null : notesCtrl.text,
              );
              if (result != null && ctx.mounted) {
                Navigator.pop(ctx);
                ref.invalidate(customersProvider(_selectedFarmId ?? ''));
              }
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }
}
