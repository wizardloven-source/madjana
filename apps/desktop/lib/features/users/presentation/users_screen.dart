import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة إدارة المستخدمين (العاملين) - للمدير
class UsersScreen extends ConsumerStatefulWidget {
  const UsersScreen({super.key});

  @override
  ConsumerState<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends ConsumerState<UsersScreen> {
  List<UserModel> _users = [];
  bool _loading = true;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';
  String get _currentUid => ref.read(authProvider).currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final users =
          await ref.read(userAdminRepositoryProvider).getUsers(_farmId);
      if (!mounted) return;
      setState(() => _users = users);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
    );
  }

  Future<bool> _confirm(String title, String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('إلغاء')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('تأكيد')),
            ],
          ),
        ) ??
        false;
  }

  /// إنشاء أو تعديل مستخدم
  Future<void> _showUserDialog({UserModel? user}) async {
    final nameCtrl = TextEditingController(text: user?.name ?? '');
    final phoneCtrl = TextEditingController(text: user?.phone ?? '');
    final pinCtrl = TextEditingController();
    UserRole role = user?.role ?? UserRole.worker;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(user == null ? 'مستخدم جديد' : 'تعديل المستخدم'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration:
                      const InputDecoration(labelText: 'الاسم الكامل'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration:
                      const InputDecoration(labelText: 'رقم الهاتف'),
                ),
                if (user == null) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: pinCtrl,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      labelText: 'الرمز السري (4-6 أرقام)',
                      counterText: '',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<UserRole>(
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'الدور'),
                  items: const [
                    DropdownMenuItem(value: UserRole.worker, child: Text('عامل')),
                    DropdownMenuItem(
                        value: UserRole.supervisor, child: Text('مشرف')),
                    DropdownMenuItem(
                        value: UserRole.manager, child: Text('مدير')),
                  ],
                  onChanged: (v) {
                    if (v != null) setDialog(() => role = v);
                  },
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
                if (user == null &&
                    !RegExp(r'^\d{4,6}$').hasMatch(pinCtrl.text)) {
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
      final repo = ref.read(userAdminRepositoryProvider);
      if (user == null) {
        await repo.createUser(
          farmId: _farmId,
          name: nameCtrl.text.trim(),
          phone: phoneCtrl.text.trim(),
          pin: pinCtrl.text,
          role: role,
        );
      } else {
        await repo.updateUser(
          uid: user.uid,
          name: nameCtrl.text.trim(),
          phone: phoneCtrl.text.trim(),
          role: role,
        );
      }
      _load();
    } catch (e) {
      _error(e);
    }
  }

  /// إعادة تعيين الرمز السري
  Future<void> _resetPin(UserModel user) async {
    final pinCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('إعادة تعيين PIN - ${user.name}'),
        content: TextField(
          controller: pinCtrl,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(
            labelText: 'الرمز الجديد (4-6 أرقام)',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              if (RegExp(r'^\d{4,6}$').hasMatch(pinCtrl.text)) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('تعيين'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(userAdminRepositoryProvider)
          .resetPin(uid: user.uid, newPin: pinCtrl.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تعيين الرمز الجديد بنجاح')));
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _deleteUser(UserModel user) async {
    if (user.uid == _currentUid) {
      _error(Exception('لا يمكنك حذف حسابك الحالي'));
      return;
    }
    final ok = await _confirm(
        'حذف مستخدم', 'هل تريد حذف "${user.name}" نهائياً؟');
    if (!ok) return;
    try {
      await ref.read(userAdminRepositoryProvider).deleteUser(user.uid);
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Chip(label: Text('عدد المستخدمين: ${_users.length}')),
              FilledButton.icon(
                onPressed: () => _showUserDialog(),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('مستخدم جديد'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Expanded(
                child: Center(child: CircularProgressIndicator()))
          else if (_users.isEmpty)
            const Expanded(child: Center(child: Text('لا يوجد مستخدمون')))
          else
            Expanded(
              child: SingleChildScrollView(
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('الاسم')),
                    DataColumn(label: Text('الهاتف')),
                    DataColumn(label: Text('الدور')),
                    DataColumn(label: Text('إجراءات')),
                  ],
                  rows: _users.map((u) {
                    final isSelf = u.uid == _currentUid;
                    return DataRow(cells: [
                      DataCell(Text(u.name)),
                      DataCell(Text(u.phone)),
                      DataCell(Chip(label: Text(u.role.label))),
                      DataCell(Row(children: [
                        IconButton(
                          tooltip: 'تعديل',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _showUserDialog(user: u),
                        ),
                        IconButton(
                          tooltip: 'إعادة تعيين PIN',
                          icon: const Icon(Icons.pin_outlined),
                          onPressed: () => _resetPin(u),
                        ),
                        if (!isSelf)
                          IconButton(
                            tooltip: 'حذف',
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.red),
                            onPressed: () => _deleteUser(u),
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
