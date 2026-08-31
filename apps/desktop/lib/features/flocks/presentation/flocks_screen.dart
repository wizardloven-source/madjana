import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:core/core.dart';
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

  void _showAddFlockOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'إضافة قطيع',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'اختر نوع الإضافة',
              style: TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            // زر قطيع جديد
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Theme.of(context).colorScheme.primary),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const NewFlockWizardScreen(),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.add_circle_outline,
                          color: Theme.of(context).colorScheme.primary,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'قطيع جديد',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'فوج جديد تمامًا - أدخل العدد والتاريخ وعدد العنابر والعامل المسؤول',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // زر قطيع قديم
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.orange.shade300),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const OldFlockWizardScreen(),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.history,
                          color: Colors.orange,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'قطيع قديم',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.orange,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'قطيع يعمل قبل النظام - أدخل الأرصدة الافتتاحية لكل عنبر',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios,
                        size: 16,
                        color: Colors.orange.shade300,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
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
                    onPressed: _showAddFlockOptions,
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة قطيع'),
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
