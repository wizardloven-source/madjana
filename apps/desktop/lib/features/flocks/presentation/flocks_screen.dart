import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:core/core.dart';
import 'package:uuid/uuid.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';
import '../../onboarding/presentation/old_flock_wizard_screen.dart';
import '../../onboarding/presentation/new_flock_wizard_screen.dart';

/// شاشة إدارة القطعان - للمدير
class FlocksScreen extends ConsumerStatefulWidget {
  const FlocksScreen({super.key});

  @override
  ConsumerState<FlocksScreen> createState() => _FlocksScreenState();
}

class _FlocksScreenState extends ConsumerState<FlocksScreen> {
  List<FlockModel> _flocks = [];
  bool _loading = true;
  bool _includeEnded = true;
  final _uuid = const Uuid();

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final flocks = await ref
          .read(flockRepositoryProvider)
          .getFlocks(_farmId, includeEnded: _includeEnded);
      if (!mounted) return;
      setState(() => _flocks = flocks);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ في التحميل: $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showFlockDialog({FlockModel? flock}) async {
    final breedCtrl = TextEditingController(text: flock?.breed ?? '');
    final countCtrl =
        TextEditingController(text: flock?.initialCount.toString() ?? '');
    DateTime startDate = flock?.startDate ?? DateTime.now();
    var initialCount = flock?.currentCount ?? 0;
    var sectionsCount = flock?.sectionsCount ?? 1;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(flock == null ? 'قطيع جديد' : 'تعديل القطيع'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: breedCtrl,
                  decoration: const InputDecoration(
                    labelText: 'السلالة',
                    hintText: 'مثال: هاي لاين بروان',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                          'تاريخ البدء: ${DateFormat('yyyy/MM/dd').format(startDate)}'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: startDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime.now().add(const Duration(days: 30)),
                        );
                        if (picked != null) setDialog(() => startDate = picked);
                      },
                      child: const Text('اختيار'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: countCtrl,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'العدد الأولي'),
                  onChanged: (v) =>
                      setDialog(() => initialCount = int.tryParse(v) ?? 0),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  value: sectionsCount,
                  decoration: const InputDecoration(
                    labelText: 'عدد العنابر',
                    helperText:
                        'سيطلب من العامل تحديد العنبر عند إدخال البيض',
                  ),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('عنبر واحد')),
                    DropdownMenuItem(value: 2, child: Text('عنبران')),
                    DropdownMenuItem(value: 3, child: Text('3 عنابر')),
                  ],
                  onChanged: (v) =>
                      setDialog(() => sectionsCount = v ?? 1),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                if (breedCtrl.text.trim().isEmpty ||
                    countCtrl.text.trim().isEmpty) {
                  return;
                }
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
      if (flock == null) {
        await ref.read(flockRepositoryProvider).createFlock(FlockModel(
              id: _uuid.v4(),
              farmId: _farmId,
              breed: breedCtrl.text.trim(),
              startDate: startDate,
              initialCount: int.parse(countCtrl.text.trim()),
              currentCount: initialCount,
              status: FlockStatus.active,
              sectionsCount: sectionsCount,
            ));
      } else {
        await ref.read(flockRepositoryProvider).updateFlock(FlockModel(
              id: flock.id,
              farmId: flock.farmId,
              breed: breedCtrl.text.trim(),
              startDate: startDate,
              initialCount: int.parse(countCtrl.text.trim()),
              currentCount: initialCount,
              status: flock.status,
              sectionsCount: sectionsCount,
            ));
      }
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _endCycle(FlockModel flock) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إنهاء الدورة'),
        content: Text(
            'هل تريد إنهاء دورة قطيع "${flock.breed}"؟ لن يستقبل التطبيق تسجيلات جديدة له.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إنهاء الدورة')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(flockRepositoryProvider).endFlock(flock.id);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _flocks.where((f) => f.status == FlockStatus.active);
    final totalBirds =
        active.fold<int>(0, (sum, f) => sum + f.currentCount);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 8,
                children: [
                  Chip(label: Text('قطعان نشطة: ${active.length}')),
                  Chip(label: Text('إجمالي الطيور: $totalBirds')),
                ],
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    label: const Text('إظهار المنتهية'),
                    selected: _includeEnded,
                    onSelected: (v) {
                      _includeEnded = v;
                      _load();
                    },
                  ),
                  FilledButton.icon(
                    onPressed: () => _showFlockDialog(),
                    icon: const Icon(Icons.add),
                    label: const Text('قطيع جديد'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const NewFlockWizardScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.playlist_add_check),
                    label: const Text('معالج فوج جديد'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const OldFlockWizardScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.history),
                    label: const Text('معالج قطيع قديم'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Expanded(
                child: Center(child: CircularProgressIndicator()))
          else if (_flocks.isEmpty)
            const Expanded(
                child: Center(child: Text('لا توجد قطعان مسجلة')))
          else
            Expanded(
              child: SingleChildScrollView(
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('السلالة')),
                    DataColumn(label: Text('تاريخ البدء')),
                    DataColumn(label: Text('العدد الأولي')),
                    DataColumn(label: Text('العدد الحالي')),
                    DataColumn(label: Text('العنابر')),
                    DataColumn(label: Text('الحالة')),
                    DataColumn(label: Text('إجراءات')),
                  ],
                  rows: _flocks.map((f) {
                    final ended = f.status == FlockStatus.depleted;
                    return DataRow(cells: [
                      DataCell(Text(f.breed)),
                      DataCell(Text(DateFormat('yyyy/MM/dd').format(f.startDate))),
                      DataCell(Text('${f.initialCount}')),
                      DataCell(Text('${f.currentCount}')),
                      DataCell(Text(f.sectionsCount > 1
                          ? '${f.sectionsCount} عنابر'
                          : 'عنبر واحد')),
                      DataCell(
                        Chip(
                          label: Text(ended ? 'منتهي' : 'نشط'),
                          backgroundColor: ended
                              ? Colors.grey.shade300
                              : Colors.green.shade100,
                        ),
                      ),
                      DataCell(Row(children: [
                        IconButton(
                          tooltip: 'تعديل',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _showFlockDialog(flock: f),
                        ),
                        if (!ended)
                          IconButton(
                            tooltip: 'إنهاء الدورة',
                            icon: const Icon(Icons.flag_outlined),
                            onPressed: () => _endCycle(f),
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
