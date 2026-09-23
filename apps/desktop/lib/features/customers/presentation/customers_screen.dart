import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../../core/shell_state.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة إدارة الزبائن - للمدير فقط
///
/// تعرض الزبائن (من السحابة والموبايل) مع ديونهم، وتتيح
/// إضافة/تعديل/حذف زبون، ويتم رفع الجديد عبر طابور المزامنة.
class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key, this.farmId, this.farmName});

  /// مدجنة محددة (يُستخدم من شاشة مدير النظام عند اختيار مدجنة).
  /// إن كانت null يُستخدم farmId الخاص بالمستخدم الحالي.
  final String? farmId;
  final String? farmName;

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  List<CustomerModel> _customers = [];
  bool _loading = true;
  String _search = '';
  int _pendingCount = 0;

  String get _farmId =>
      widget.farmId ?? ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final repo = ref.read(dispatchRepositoryProvider);
    try {
      // مزامنة نشطة أولاً: رفع المعلّق ثم سحب كل السجلات من السحابة
      await ref.read(syncRepositoryProvider).syncNow(_farmId);
      _pendingCount = await ref.read(syncRepositoryProvider).getPendingCount();
      final customers = await repo.getCustomers(_farmId);
      if (!mounted) return;
      setState(() => _customers = customers);
    } catch (_) {
      final customers = await repo.getCustomers(_farmId);
      if (!mounted) return;
      setState(() => _customers = customers);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<CustomerModel> get _filtered {
    if (_search.isEmpty) return _customers;
    return _customers
        .where((c) => c.name.contains(_search) || c.phone.contains(_search))
        .toList();
  }

  Future<void> _showCustomerDialog({CustomerModel? customer}) async {
    final nameCtrl = TextEditingController(text: customer?.name ?? '');
    final phoneCtrl = TextEditingController(text: customer?.phone ?? '');
    final notesCtrl = TextEditingController(text: customer?.notes ?? '');
    var isGlobal = customer?.isGlobal ?? false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(customer == null ? 'زبون جديد' : 'تعديل الزبون'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'اسم الزبون'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration:
                      const InputDecoration(labelText: 'رقم الهاتف'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  decoration:
                      const InputDecoration(labelText: 'ملاحظات (اختياري)'),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: isGlobal,
                  onChanged: (v) => setDialogState(() => isGlobal = v),
                  title: const Text('مرئي لكل المداجن (زبون عام)'),
                  subtitle: Text(isGlobal
                      ? 'يظهر في كل المداجن ويمكن التخريج له منها'
                      : 'مرتبط بهذه المدجنة فقط'),
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
                if (nameCtrl.text.trim().isEmpty ||
                    phoneCtrl.text.trim().isEmpty) {
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

    final repo = ref.read(dispatchRepositoryProvider);
    try {
      if (customer == null) {
        await repo.addCustomer(CustomerModel(
          farmId: _farmId,
          name: nameCtrl.text.trim(),
          phone: phoneCtrl.text.trim(),
          notes: notesCtrl.text.trim().isEmpty
              ? null
              : notesCtrl.text.trim(),
          isGlobal: isGlobal,
        ));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isGlobal
                ? 'تمت إضافة زبون عام (يظهر لكل المداجن)'
                : 'تمت إضافة الزبون (مرتبط بهذه المدجنة)')));
      } else {
        await repo.updateCustomer(CustomerModel(
          id: customer.id,
          farmId: customer.farmId,
          name: nameCtrl.text.trim(),
          phone: phoneCtrl.text.trim(),
          notes: notesCtrl.text.trim().isEmpty
              ? null
              : notesCtrl.text.trim(),
          totalDebt: customer.totalDebt,
          isGlobal: isGlobal,
        ));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isGlobal
                ? 'تم تعديل الزبون — أصبح مرئياً لكل المداجن'
                : 'تم تعديل الزبون — مرتبط بهذه المدجنة')));
      }
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _deleteCustomer(CustomerModel customer) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف زبون'),
        content: Text('هل تريد حذف "${customer.name}" نهائياً؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تأكيد')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(dispatchRepositoryProvider)
          .deleteCustomer(customer.id!);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dataRefreshTickProvider, (_, __) => _load());
    final currency = ref.watch(currencyProvider).value ?? '';
    final totalDebt =
        _customers.fold<double>(0, (sum, c) => sum + c.totalDebt);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Chip(
                label: Text(
                    'عدد الزبائن: ${_customers.length} - إجمالي الديون: ${totalDebt.toStringAsFixed(2)} $currency'),
              ),
              if (_pendingCount > 0)
                Tooltip(
                  message:
                      'سجلات محلية لم تصل للسحابة بعد (غالباً بسبب صلاحيات قاعدة البيانات)',
                  child: Chip(
                    avatar: const Icon(Icons.cloud_off, size: 16),
                    label: Text('$_pendingCount قيد الترقيع'),
                    backgroundColor: Colors.orange.shade100,
                  ),
                ),
              Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'تحديث',
                  icon: const Icon(Icons.refresh),
                  onPressed: _load,
                ),
                FilledButton.icon(
                  onPressed: () => _showCustomerDialog(),
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('زبون جديد'),
                ),
              ]),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 320,
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                labelText: 'بحث باسم الزبون أو الهاتف...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Expanded(
                child: Center(child: CircularProgressIndicator()))
          else if (_filtered.isEmpty)
            const Expanded(child: Center(child: Text('لا يوجد زبائن')))
          else
            Expanded(
              child: SingleChildScrollView(
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('الاسم')),
                    DataColumn(label: Text('الهاتف')),
                    DataColumn(label: Text('الديون')),
                    DataColumn(label: Text('الملاحظات')),
                    DataColumn(label: Text('النطاق')),
                    DataColumn(label: Text('إجراءات')),
                  ],
                  rows: _filtered.map((c) {
                    return DataRow(cells: [
                      DataCell(Text(c.name)),
                      DataCell(Text(c.phone)),
                      DataCell(Text(
                        '${c.totalDebt.toStringAsFixed(2)} $currency',
                        style: TextStyle(
                          color: c.totalDebt > 0
                              ? Theme.of(context).colorScheme.error
                              : null,
                          fontWeight: c.totalDebt > 0
                              ? FontWeight.w700
                              : FontWeight.normal,
                        ),
                      )),
                      DataCell(Text(c.notes ?? '-')),
                      DataCell(c.isGlobal
                          ? Chip(
                              avatar: const Icon(Icons.public, size: 14),
                              label: const Text('عام'),
                              backgroundColor: Colors.blue.shade50,
                              visualDensity: VisualDensity.compact,
                            )
                          : const Text('المدجنة')),
                      DataCell(Row(children: [
                        IconButton(
                          tooltip: 'تعديل',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _showCustomerDialog(customer: c),
                        ),
                        IconButton(
                          tooltip: 'حذف',
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          onPressed: () => _deleteCustomer(c),
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