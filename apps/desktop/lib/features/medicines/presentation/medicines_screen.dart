import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';

class MedicinesScreen extends ConsumerStatefulWidget {
  const MedicinesScreen({super.key});
  @override
  ConsumerState<MedicinesScreen> createState() => _MedicinesScreenState();
}

class _MedicinesScreenState extends ConsumerState<MedicinesScreen> {
  List<MedicineModel> _medicines = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final repo = ref.read(medicationRepositoryProvider);
      _medicines = await repo.getMedicinesCatalog();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
    );
  }

  String _typeLabel(MedicationType t) {
    switch (t) {
      case MedicationType.drug:
        return 'دواء';
      case MedicationType.vaccine:
        return 'لقاح';
      case MedicationType.vitamin:
        return 'فيتامين';
    }
  }

  Future<void> _showAddDialog() async {
    final nameCtrl = TextEditingController();
    var selectedType = MedicationType.drug;
    final withdrawalCtrl = TextEditingController(text: '0');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('إضافة دواء'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration:
                      const InputDecoration(labelText: 'اسم الدواء'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<MedicationType>(
                  value: selectedType,
                  decoration: const InputDecoration(labelText: 'النوع'),
                  items: MedicationType.values
                      .map((t) => DropdownMenuItem(
                          value: t, child: Text(_typeLabel(t))))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDialog(() => selectedType = v);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: withdrawalCtrl,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'أيام السحب'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    try {
      final repo = ref.read(medicationRepositoryProvider);
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      await repo.saveMedicine(MedicineModel(
        id: id,
        name: nameCtrl.text.trim(),
        type: selectedType,
        withdrawalDays: int.tryParse(withdrawalCtrl.text.trim()) ?? 0,
      ));
      _load();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _showEditDialog(MedicineModel med) async {
    final nameCtrl = TextEditingController(text: med.name);
    var selectedType = med.type;
    final withdrawalCtrl = TextEditingController(text: '${med.withdrawalDays}');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('تعديل الدواء'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration:
                      const InputDecoration(labelText: 'اسم الدواء'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<MedicationType>(
                  value: selectedType,
                  decoration: const InputDecoration(labelText: 'النوع'),
                  items: MedicationType.values
                      .map((t) => DropdownMenuItem(
                          value: t, child: Text(_typeLabel(t))))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDialog(() => selectedType = v);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: withdrawalCtrl,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'أيام السحب'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    try {
      final repo = ref.read(medicationRepositoryProvider);
      await repo.saveMedicine(MedicineModel(
        id: med.id,
        name: nameCtrl.text.trim(),
        type: selectedType,
        withdrawalDays: int.tryParse(withdrawalCtrl.text.trim()) ?? 0,
      ));
      _load();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _delete(MedicineModel med) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الدواء'),
        content: Text('هل تريد حذف "${med.name}"؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await ref.read(medicationRepositoryProvider).deleteMedicine(med.id);
      _load();
    } catch (e) {
      _error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'إدارة الأدوية',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              FilledButton.icon(
                onPressed: _showAddDialog,
                icon: const Icon(Icons.add),
                label: const Text('إضافة دواء'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Expanded(
                child: Center(child: CircularProgressIndicator()))
          else if (_medicines.isEmpty)
            const Expanded(child: Center(child: Text('لا توجد أدوية')))
          else
            Expanded(
              child: SingleChildScrollView(
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('اسم الدواء')),
                    DataColumn(label: Text('النوع')),
                    DataColumn(label: Text('أيام السحب')),
                    DataColumn(label: Text('إجراءات')),
                  ],
                  rows: _medicines.map((med) {
                    return DataRow(cells: [
                      DataCell(Text(med.name)),
                      DataCell(Text(_typeLabel(med.type))),
                      DataCell(Text('${med.withdrawalDays}')),
                      DataCell(Row(children: [
                        IconButton(
                          tooltip: 'تعديل',
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () => _showEditDialog(med),
                        ),
                        IconButton(
                          tooltip: 'حذف',
                          icon: const Icon(Icons.delete_outline,
                              size: 20, color: Colors.red),
                          onPressed: () => _delete(med),
                        ),
                      ])),
                    ]);
                  }).toList(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
