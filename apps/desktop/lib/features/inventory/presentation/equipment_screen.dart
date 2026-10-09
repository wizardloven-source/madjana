import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة العدة والأجهزة مجمّعة حسب القطيع.
///
/// مجموعتان: «مشترك» (صنف واحد لكل المزارع) ولكل قطيع ما سُند إليه.
/// الكمية المعروضة هي رصيد المخزون العام للصنف، وليست حصة القطيع: `flock_id`
/// مرجع للعرض لا توزيع، فمجموع عمود الكمية قد يفوق المخزون.
class EquipmentScreen extends ConsumerStatefulWidget {
  const EquipmentScreen({super.key});

  @override
  ConsumerState<EquipmentScreen> createState() => _EquipmentScreenState();
}

class _EquipmentScreenState extends ConsumerState<EquipmentScreen> {
  List<InventoryItemModel> _items = [];
  List<FlockModel> _flocks = [];
  bool _loading = true;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await ref
          .read(inventoryRepositoryProvider)
          .getItems(_farmId);
      final flocks = await ref
          .read(flockRepositoryProvider)
          .getFlocks(_farmId, includeEnded: true);
      if (!mounted) return;
      setState(() {
        _items = items;
        _flocks = flocks;
      });
    } catch (e) {
      debugPrint('madjana: equipment load skipped: $e');
      // التصفير يبقى على ما كان؛ الشاشة تعرض حالة فارغة قابلة للتجربة.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<InventoryItemModel> get _shared =>
      _items.where((i) => i.flockId == null).toList();

  List<InventoryItemModel> _ofFlock(String flockId) =>
      _items.where((i) => i.flockId == flockId).toList();

  /// القطعان التي سُند إليها عدة فعلاً. القطعان الفارغة لا تظهر حتى لا
  /// تتحول القائمة إلى صفحات فارغة.
  List<FlockModel> get _flocksWithEquipment =>
      _flocks.where((f) => _ofFlock(f.id).isNotEmpty).toList();

  FlockModel? _flockById(String? id) {
    if (id == null) return null;
    for (final f in _flocks) {
      if (f.id == id) return f;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return const Center(
        child: Text('لا توجد عناصر مخزون بعد.\nأضفها من شاشة المخزون.'),
      );
    }

    final groups = <Widget>[];
    if (_shared.isNotEmpty) {
      groups.add(
        _group(
          'مشترك — كل المزارع',
          Icons.public,
          _shared,
          subtitle: 'صنف واحد يخدم أكثر من قطيع',
        ),
      );
    }
    for (final f in _flocksWithEquipment) {
      groups.add(
        _group(
          f.displayName,
          Icons.egg_alt,
          _ofFlock(f.id),
          subtitle: '${f.sectionsCount} قسيم',
        ),
      );
    }

    // أصناف مُسنَدة إلى قطعان محذوفة: لا نخفيها صامتة.
    final orphans = _items
        .where((i) => i.flockId != null && _flockById(i.flockId) == null)
        .toList();
    if (orphans.isNotEmpty) {
      groups.add(
        _group(
          'قطيع غير موجود',
          Icons.help_outline,
          orphans,
          subtitle: 'مُسنَد إلى قطيع حُذف — أعد الإسناد لتظهر صحّة',
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('العدة والأجهزة', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'الكمية رصيد المخزون العام، وإسناد القطيع للعرض فقط — لا تُحسب كحصة له.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        ...groups,
      ],
    );
  }

  Widget _group(
    String title,
    IconData icon,
    List<InventoryItemModel> items, {
    String? subtitle,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        initiallyExpanded: true,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(
          subtitle ?? '${items.length} عنصر',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: Chip(label: Text('${items.length}')),
        children: [
          for (final i in items)
            ListTile(
              dense: true,
              title: Text(i.name),
              subtitle: Text(
                i.isLowStock
                    ? 'الكمية منخفضة'
                    : 'حد التنبيه: ${NumberFormat('#,##0.##').format(i.lowStockThreshold)}',
                style: TextStyle(color: i.isLowStock ? Colors.red : null),
              ),
              trailing: Text(
                '${NumberFormat('#,##0.##').format(i.quantity)} ${i.unit.label}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
    );
  }
}
