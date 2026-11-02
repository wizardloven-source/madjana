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
  /// State predicate: تعيد farmId المستخدم الحالي من provider المحلّي،
  /// فتتجدد الشاشة تلقائياً عند تبديل المزرعة عبر setActiveFarm.
  String get _currentFarmId {
    final user = ref.watch(authProvider).currentUser;
    // إذا كان مستخدم系统管理/admin، يرى كل المزارع ويعمل farmId فارغ (global)
    if (user?.isSystemAdmin ?? false) return '';
    // Otherwise use the selected farm or the user's default farm
    return _selectedFarmId ?? (user?.farmId ?? '');
  }

  @override
  void initState() {
    super.initState();
    // للاستماع لتغييرات farmId عبر authProvider (setActiveFarm)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Riverpod ستعيد البناء تلقائياً عند تغيير state
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final farmId = _currentFarmId;
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
      builder: (ctx) {
        var saving = false;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('إضافة زبون جديد'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'الاسم')),
                  const SizedBox(height: 12),
                  TextField(controller: phoneCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف')),
                  const SizedBox(height: 12),
                  // علم "مرئي لكل المزارع"
                  SwitchListTile(
                    title: const Text('مرئي لكل المزارع'),
                    value: isGlobal,
                    onChanged: (bool value) {
                      setDialogState(() => isGlobal = value);
                    },
                    secondary: const Icon(Icons.public),
                  ),
                  const SizedBox(height: 8),
                  TextField(controller: notesCtrl, decoration: const InputDecoration(labelText: 'ملاحظات'), maxLines: 2),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(ctx),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (nameCtrl.text.isEmpty || phoneCtrl.text.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('أدخل الاسم ورقم الهاتف')),
                          );
                          return;
                        }
                        setDialogState(() => saving = true);
                        try {
                          final result = await ref
                              .read(dispatchProvider.notifier)
                              .addNewCustomer(
                                farmId: _currentFarmId,
                                name: nameCtrl.text,
                                phone: phoneCtrl.text,
                                notes: notesCtrl.text.isEmpty
                                    ? null
                                    : notesCtrl.text,
                                isGlobal: isGlobal,
                              );
                          if (result != null && ctx.mounted) {
                            Navigator.pop(ctx);
                            ref.invalidate(
                                customersProvider(_currentFarmId)));
                          } else if (ctx.mounted) {
                            setDialogState(() => saving = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('تعذّر إضافة الزبون')),
                            );
                          }
                        } catch (e) {
                          debugPrint('addNewCustomer failed: $e');
                          if (ctx.mounted) {
                            setDialogState(() => saving = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('تعذّر إضافة الزبون')),
                            );
                          }
                        }
                      },
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('حفظ'),
              ),
            ],
          ),
        );
      },
    );
  }
}
