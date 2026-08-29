import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/date_picker_field.dart';
import '../../auth/providers/auth_provider.dart';
import '../../reference_data/providers/reference_data_provider.dart';

/// شاشة إدارة القطعان من الموبايل
class FlockManagementScreen extends ConsumerStatefulWidget {
  const FlockManagementScreen({super.key});
  @override
  ConsumerState<FlockManagementScreen> createState() => _FlockManagementScreenState();
}

class _FlockManagementScreenState extends ConsumerState<FlockManagementScreen> {
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
    final flocksAsync = ref.watch(flocksProvider(farmId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('القطعان'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showAddDialog(context, ref),
          ),
        ],
      ),
      body: flocksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('خطأ: $e')),
        data: (flocks) {
          if (flocks.isEmpty) {
            return const Center(child: Text('لا توجد قطعان'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: flocks.length,
            itemBuilder: (context, index) {
              final flock = flocks[index];
              final isActive = flock.status == FlockStatus.active;
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isActive
                        ? Colors.green.withValues(alpha: 0.15)
                        : Colors.grey.withValues(alpha: 0.15),
                    child: Icon(Icons.pets, color: isActive ? Colors.green : Colors.grey),
                  ),
                  title: Text(flock.breed, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    '${flock.currentCount} طائر من أصل ${flock.initialCount}\n'
                    'تاريخ البداية: ${Formatters.formatDate(flock.startDate)}',
                  ),
                  isThreeLine: true,
                  trailing: PopupMenuButton(
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'edit', child: Text('تعديل')),
                      if (isActive) const PopupMenuItem(value: 'end', child: Text('إنهاء الدورة')),
                    ],
                    onSelected: (value) {
                      if (value == 'edit') _showEditDialog(context, ref, flock);
                      if (value == 'end') _confirmEndFlock(context, ref, flock);
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showAddDialog(BuildContext context, WidgetRef ref) {
    final breedCtrl = TextEditingController();
    final countCtrl = TextEditingController();
    final sectionsCtrl = TextEditingController(text: '1');
    DateTime startDate = DateTime.now();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة قطيع جديد'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: breedCtrl, decoration: const InputDecoration(labelText: 'السلالة')),
              const SizedBox(height: 12),
              TextField(controller: countCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'عدد الطيور')),
              const SizedBox(height: 12),
              TextField(controller: sectionsCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'عدد العنابر')),
              const SizedBox(height: 12),
              DatePickerField(
                value: startDate,
                label: 'تاريخ البداية',
                onChanged: (d) => startDate = d,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () async {
              final farmId = _selectedFarmId ?? '';
              final breed = breedCtrl.text;
              final count = int.tryParse(countCtrl.text) ?? 0;
              final sections = int.tryParse(sectionsCtrl.text) ?? 1;
              if (breed.isEmpty || count <= 0) return;
              final repo = ref.read(flockRepositoryProvider);
              await repo.createFlock(FlockModel(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                farmId: farmId,
                breed: breed,
                startDate: startDate,
                initialCount: count,
                currentCount: count,
                sectionsCount: sections,
              ));
              if (ctx.mounted) Navigator.pop(ctx);
              ref.invalidate(flocksProvider(farmId));
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BuildContext context, WidgetRef ref, FlockModel flock) {
    final countCtrl = TextEditingController(text: '${flock.currentCount}');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعديل القطيع'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('سلالة: ${flock.breed}', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(controller: countCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'العدد الحالي')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () async {
              final count = int.tryParse(countCtrl.text) ?? flock.currentCount;
              final repo = ref.read(flockRepositoryProvider);
              await repo.updateFlock(FlockModel(
                id: flock.id,
                farmId: flock.farmId,
                breed: flock.breed,
                startDate: flock.startDate,
                initialCount: flock.initialCount,
                currentCount: count,
                status: flock.status,
                sectionsCount: flock.sectionsCount,
              ));
              if (ctx.mounted) Navigator.pop(ctx);
              ref.invalidate(flocksProvider(_selectedFarmId ?? ''));
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  void _confirmEndFlock(BuildContext context, WidgetRef ref, FlockModel flock) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إنهاء دورة القطيع'),
        content: Text('هل تريد إنهاء دورة "${flock.breed}"؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () async {
              await ref.read(flockRepositoryProvider).endFlock(flock.id);
              if (ctx.mounted) Navigator.pop(ctx);
              ref.invalidate(flocksProvider(_selectedFarmId ?? ''));
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('إنهاء'),
          ),
        ],
      ),
    );
  }
}
