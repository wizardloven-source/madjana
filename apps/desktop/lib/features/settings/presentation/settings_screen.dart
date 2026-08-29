import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:core/core.dart';
import 'package:data/data.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

/// شاشة الإعدادات: بيانات المدجنة + عملة النظام + النسخ الاحتياطي
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  FarmModel? _farm;
  bool _loading = true;
  late TextEditingController _nameCtrl;
  late TextEditingController _locationCtrl;
  final _currencyCtrl = TextEditingController();

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _locationCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _locationCtrl.dispose();
    _currencyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final farm = await ref.read(farmRepositoryProvider).getFarm(_farmId);
      final currency = await ref.read(farmRepositoryProvider).getCurrency();
      if (!mounted) return;
      setState(() {
        _farm = farm;
        _nameCtrl.text = farm.name;
        _locationCtrl.text = farm.location ?? '';
        _currencyCtrl.text = currency;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذّر تحميل بيانات المدجنة')));
    }
  }

  Future<void> _saveFarm() async {
    if (_farm == null || _nameCtrl.text.trim().isEmpty) return;
    try {
      final updated = FarmModel(
        id: _farm!.id,
        name: _nameCtrl.text.trim(),
        location: _locationCtrl.text.trim().isEmpty
            ? null
            : _locationCtrl.text.trim(),
        ownerId: _farm!.ownerId,
        createdAt: _farm!.createdAt,
      );
      await ref.read(farmRepositoryProvider).updateFarm(updated);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ بيانات المدجنة')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذّر الحفظ - تأكد من الاتصال')));
    }
  }

  Future<void> _saveCurrency() async {
    final symbol = _currencyCtrl.text.trim();
    if (symbol.isEmpty) return;
    await ref.read(farmRepositoryProvider).setCurrency(symbol);
    ref.invalidate(currencyProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('تم تغيير العملة إلى $symbol')));
  }

  // ─────────────── النسخ الاحتياطي ───────────────

  Future<Directory> _getBackupDir() async {
    final dbPath = await LocalDatabase.databasePath();
    final dir = Directory(p.join(p.dirname(dbPath), 'madjana_backups'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  List<File> _listBackups(Directory dir) {
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.db'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  }

  Future<void> _createBackup() async {
    try {
      final dbPath = await LocalDatabase.databasePath();
      final source = File(dbPath);
      if (!await source.exists()) {
        throw Exception('ملف القاعدة غير موجود');
      }
      // إغلاق الاتصال لضمان نسخة متسقة
      await LocalDatabase.close();
      final dir = await _getBackupDir();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final target = p.join(dir.path, 'poultry_farm_$stamp.db');
      await source.copy(target);

      // إعادة فتح قاعدة البيانات بعد النسخ
      await LocalDatabase.database;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم إنشاء نسخة احتياطية: ${p.basename(target)}')));
      setState(() {}); // لتحديث قائمة النسخ
    } catch (e) {
      // التأكد من إعادة فتح القاعدة حتى في حالة الخطأ
      try { await LocalDatabase.database; } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('فشل النسخ: $e')));
    }
  }

  Future<void> _restoreBackup(File backup) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('استعادة نسخة احتياطية'),
        content: Text(
            'سيتم استبدال البيانات المحلية الحالية بالنسخة "${p.basename(backup.path)}".\n\nملاحظة: استمر بعد الاستعادة يتطلب إعادة تشغيل التطبيق.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('استعادة')),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final dbPath = await LocalDatabase.databasePath();
      await LocalDatabase.close();
      await backup.copy(dbPath);

      // إعادة فتح قاعدة البيانات بالنسخة المستعادة
      await LocalDatabase.database;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'تمت الاستعادة. أعد تشغيل التطبيق لتطبيق البيانات المستعادة.')));
    } catch (e) {
      // التأكد من إعادة فتح القاعدة حتى في حالة الخطأ
      try { await LocalDatabase.database; } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('فشلت الاستعادة: $e')));
    }
  }

  Future<void> _deleteBackup(File backup) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف النسخة الاحتياطية'),
        content: Text(
            'هل تريد حذف "${p.basename(backup.path)}"؟\nلا يمكن التراجع عن هذا الإجراء.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await backup.delete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم حذف "${p.basename(backup.path)}"')));
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('فشل الحذف: $e')));
    }
  }

  Future<void> _deleteOldBackups() async {
    try {
      final dir = await _getBackupDir();
      final files = _listBackups(dir);
      if (files.length <= 1) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('لا توجد نسخ قديمة للحذف')));
        return;
      }

      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('حذف النسخ القديمة'),
          content: Text(
              'سيتم حذف ${files.length - 1} نسخة احتياطية (الأقدم).\nالنسخة الأحدث فقط ستبقى.\n\nهل تريد المتابعة؟'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('حذف'),
            ),
          ],
        ),
      );
      if (ok != true) return;

      var deleted = 0;
      for (final f in files.skip(1)) {
        await f.delete();
        deleted++;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم حذف $deleted نسخة احتياطية')));
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('فشل الحذف: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          // ─── بيانات المدجنة ───
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.agriculture_outlined),
                    const SizedBox(width: 8),
                    Text('بيانات المدجنة',
                        style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'اسم المدجنة',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _locationCtrl,
                    decoration: const InputDecoration(
                      labelText: 'الموقع',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _saveFarm,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('حفظ التعديلات'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ─── العملة ───
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.payments_outlined),
                    const SizedBox(width: 8),
                    Text('عملة النظام',
                        style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 16),
                  Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final c in ['ل.س', '\$', '€', 'ر.س', 'ج.م'])
                        ChoiceChip(
                          label: Text(c),
                          selected: _currencyCtrl.text == c,
                          onSelected: (_) {
                            setState(() => _currencyCtrl.text = c);
                            _saveCurrency();
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ─── النسخ الاحتياطي ───
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.backup_outlined),
                    const SizedBox(width: 8),
                    Text('النسخ الاحتياطي والاستعادة',
                        style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 8),
                  const Text(
                      'نسخة كاملة من قاعدة البيانات المحلية تُحفظ في مجلد madjana_backups.'),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: _createBackup,
                    icon: const Icon(Icons.backup_outlined),
                    label: const Text('إنشاء نسخة احتياطية الآن'),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: _deleteOldBackups,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: const Text('حذف النسخ الاحتياطية القديمة'),
                    style: FilledButton.styleFrom(
                        foregroundColor: Colors.red.shade700),
                  ),
                  const SizedBox(height: 16),
                  FutureBuilder<Directory>(
                    future: _getBackupDir(),
                    builder: (ctx, snap) {
                      if (!snap.hasData) return const SizedBox.shrink();
                      final files = _listBackups(snap.data!);
                      if (files.isEmpty) {
                        return const Text('لا توجد نسخ محفوظة بعد');
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('النسخ المتوفرة (${files.length}):',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          ...files.map((f) => ListTile(
                                dense: true,
                                leading:
                                    const Icon(Icons.description_outlined),
                                title: Text(p.basename(f.path)),
                                subtitle: Text(DateFormat(
                                        'yyyy/MM/dd - HH:mm')
                                    .format(f.statSync().modified)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    FilledButton.tonal(
                                      onPressed: () => _restoreBackup(f),
                                      child: const Text('استعادة'),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      tooltip: 'حذف النسخة',
                                      icon: const Icon(Icons.delete_outline,
                                          color: Colors.red, size: 20),
                                      onPressed: () => _deleteBackup(f),
                                    ),
                                  ],
                                ),
                              )),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
