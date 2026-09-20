import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:core/core.dart';
import 'package:data/data.dart';
import '../../../core/providers.dart';
import '../../../core/theme_provider.dart';
import '../../auth/providers/auth_provider.dart';
import '../../users/presentation/users_screen.dart';

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
  AppCurrency _inputCurrency = AppCurrency.dollar;

  late TextEditingController _feedBagWeightCtrl;
  late TextEditingController _eggsPerCartonCtrl;
  late TextEditingController _eggsPerTrayCtrl;
  late TextEditingController _mortalityRateCtrl;
  late TextEditingController _cartonThresholdCtrl;

  bool _lowStockAlert = true;
  bool _mortalityAlert = true;
  String _selectedLanguage = 'العربية';
  late TextEditingController _exchangeRateCtrl;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  /// شاشة إدارة المستخدمين داخل الإعدادات مناسبة للمدير فقط؛
  /// مدير النظام يستخدمها من الشريط الجانبي حيث تُربط بالمدجنة المختارة.
  bool get _canManageUsers =>
      ref.read(authProvider).currentUser?.role != UserRole.system_admin;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _locationCtrl = TextEditingController();
    _feedBagWeightCtrl = TextEditingController();
    _eggsPerCartonCtrl = TextEditingController();
    _eggsPerTrayCtrl = TextEditingController();
    _mortalityRateCtrl = TextEditingController();
    _cartonThresholdCtrl = TextEditingController();
    _exchangeRateCtrl = TextEditingController(text: '1.0');
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _locationCtrl.dispose();
    _feedBagWeightCtrl.dispose();
    _eggsPerCartonCtrl.dispose();
    _eggsPerTrayCtrl.dispose();
    _mortalityRateCtrl.dispose();
    _cartonThresholdCtrl.dispose();
    _exchangeRateCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final farm = await ref.read(farmRepositoryProvider).getFarm(_farmId);
      final inputCurrency =
          await ref.read(farmRepositoryProvider).getInputCurrency();
      final feedWeight = await ref.read(farmRepositoryProvider).getFeedBagWeightKg();
      final eggsCarton = await ref.read(farmRepositoryProvider).getEggsPerCarton();
      final eggsTray = await ref.read(farmRepositoryProvider).getEggsPerTray();
      final mortalityRate = await ref.read(farmRepositoryProvider).getDefaultMortalityRate();
      final cartonThreshold =
          await ref.read(farmRepositoryProvider).getCartonLowThreshold();

      if (!mounted) return;
      setState(() {
        _farm = farm;
        _nameCtrl.text = farm.name;
        _locationCtrl.text = farm.location ?? '';
        _inputCurrency = inputCurrency;
        _feedBagWeightCtrl.text = feedWeight.toString();
        _eggsPerCartonCtrl.text = eggsCarton.toString();
        _eggsPerTrayCtrl.text = eggsTray.toString();
        _mortalityRateCtrl.text = mortalityRate.toString();
        _cartonThresholdCtrl.text = cartonThreshold.toString();
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

  Future<void> _saveInputCurrency() async {
    await ref.read(farmRepositoryProvider).setInputCurrency(_inputCurrency);
    ref.invalidate(currencyProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'تم تعيين عملة الإدخال إلى ${_inputCurrency.label} - العرض بالدولار دائماً')));
  }

  Future<FarmModel?> _updatedFarm({
    double? feedWeight,
    int? eggsCarton,
    int? eggsTray,
    double? mortalityRate,
    int? cartonThreshold,
  }) async {
    final farm = _farm;
    if (farm == null) return null;
    final updated = FarmModel(
      id: farm.id,
      name: farm.name,
      location: farm.location,
      ownerId: farm.ownerId,
      createdAt: farm.createdAt,
      feedBagWeightKg: feedWeight ?? farm.feedBagWeightKg,
      eggsPerCarton: eggsCarton ?? farm.eggsPerCarton,
      eggsPerTray: eggsTray ?? farm.eggsPerTray,
      defaultMortalityRate: mortalityRate ?? farm.defaultMortalityRate,
      cartonLowThreshold: cartonThreshold ?? farm.cartonLowThreshold,
    );
    await ref.read(farmRepositoryProvider).updateSettings(updated);
    return updated;
  }

  Future<void> _saveFeedBagWeight() async {
    final value = double.tryParse(_feedBagWeightCtrl.text);
    if (value == null || value <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء إدخال وزن صحيح')));
      return;
    }
    if (_farm == null) {
      await ref.read(farmRepositoryProvider).setFeedBagWeightKg(value);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('غير متصل - حُفظ محلياً مؤقتاً')));
      return;
    }
    final updated = await _updatedFarm(feedWeight: value);
    if (!mounted) return;
    if (updated != null) setState(() => _farm = updated);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم حفظ وزن الكيس: ${value.toStringAsFixed(1)} كغ (للموبايل)')));
  }

  Future<void> _saveEggsPerCarton() async {
    final value = int.tryParse(_eggsPerCartonCtrl.text);
    if (value == null || value <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء إدخال عدد صحيح')));
      return;
    }
    if (_farm == null) {
      await ref.read(farmRepositoryProvider).setEggsPerCarton(value);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('غير متصل - حُفظ محلياً مؤقتاً')));
      return;
    }
    final updated = await _updatedFarm(eggsCarton: value);
    if (!mounted) return;
    if (updated != null) setState(() => _farm = updated);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم حفظ عدد البيض في الكرتون: $value بيضة (للموبايل)')));
  }

  Future<void> _saveEggsPerTray() async {
    final value = int.tryParse(_eggsPerTrayCtrl.text);
    if (value == null || value <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء إدخال عدد صحيح')));
      return;
    }
    if (_farm == null) {
      await ref.read(farmRepositoryProvider).setEggsPerTray(value);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('غير متصل - حُفظ محلياً مؤقتاً')));
      return;
    }
    final updated = await _updatedFarm(eggsTray: value);
    if (!mounted) return;
    if (updated != null) setState(() => _farm = updated);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم حفظ عدد البيض في الصينية: $value بيضة (للموبايل)')));
  }

  Future<void> _saveMortalityRate() async {
    final value = double.tryParse(_mortalityRateCtrl.text);
    if (value == null || value < 0 || value > 100) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء إدخال نسبة صحيحة (0-100)')));
      return;
    }
    if (_farm == null) {
      await ref.read(farmRepositoryProvider).setDefaultMortalityRate(value);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('غير متصل - حُفظ محلياً مؤقتاً')));
      return;
    }
    final updated = await _updatedFarm(mortalityRate: value);
    if (!mounted) return;
    if (updated != null) setState(() => _farm = updated);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم حفظ معدل النفوق الافتراضي: ${value.toStringAsFixed(1)}% (للموبايل)')));
  }

  Future<void> _saveCartonThreshold() async {
    final value = int.tryParse(_cartonThresholdCtrl.text);
    if (value == null || value <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء إدخال عدد صحيح')));
      return;
    }
    if (_farm == null) {
      await ref.read(farmRepositoryProvider).setCartonLowThreshold(value);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('غير متصل - حُفظ محلياً مؤقتاً')));
      return;
    }
    final updated = await _updatedFarm(cartonThreshold: value);
    if (!mounted) return;
    if (updated != null) setState(() => _farm = updated);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم حفظ حد التنبيه: $value صحن كرتون')));
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
      await LocalDatabase.close();
      final dir = await _getBackupDir();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final target = p.join(dir.path, 'poultry_farm_$stamp.db');
      await source.copy(target);

      await LocalDatabase.database;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم إنشاء نسخة احتياطية: ${p.basename(target)}')));
      setState(() {});
    } catch (e) {
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

      await LocalDatabase.database;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'تمت الاستعادة. أعد تشغيل التطبيق لتطبيق البيانات المستعادة.')));
    } catch (e) {
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

  // ─────────────── نسخ احتياطي سحابي ───────────────

  Future<void> _backupToCloud() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('النسخ الاحتياطي السحابي'),
        content: const Text(
            'سيتم رفع نسخة احتياطية من قاعدة البيانات إلى Supabase Cloud.\n\nهل تريد المتابعة؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('رفع')),
        ],
      ),
    );
    if (ok != true) return;

    try {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('جاري رفع النسخة الاحتياطية...')));

      final dbPath = await LocalDatabase.databasePath();
      final source = File(dbPath);
      if (!await source.exists()) {
        throw Exception('ملف القاعدة غير موجود');
      }

      await LocalDatabase.close();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final backupName = 'madjana_backup_$stamp.db';

      try {
        final tempDir = Directory.systemTemp;
        final tempFile = File(p.join(tempDir.path, backupName));
        await source.copy(tempFile.path);
        final storage = ref.read(supabaseClientProvider).storage;
        await storage.from('backups').upload(
          backupName,
          tempFile,
        );
        await tempFile.delete();
      } finally {
        await LocalDatabase.database;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم رفع النسخة الاحتياطية بنجاح')));
    } catch (e) {
      try { await LocalDatabase.database; } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('فشل الرفع السحابي: $e')));
    }
  }

  // ─────────────── تصدير CSV ───────────────

  Future<void> _exportDataAsCsv() async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('جاري تصدير البيانات...')));

      final flocks = await ref.read(flockRepositoryProvider).getFlocks(_farmId);
      final eggs = await ref
          .read(eggProductionRepositoryProvider)
          .getAllRecords(farmId: _farmId);
      final mortality = await ref
          .read(mortalityRepositoryProvider)
          .getAllRecords(farmId: _farmId);

      final buffer = StringBuffer();
      buffer.writeln('=== القطعان ===');
      buffer.writeln('السلالة,تاريخ البدء,العدد الأولي,العدد الحالي,الحالة');
      for (final f in flocks) {
        buffer.writeln(
            '${f.breed},${DateFormat('yyyy/MM/dd').format(f.startDate)},${f.initialCount},${f.currentCount},${f.status.name}');
      }

      buffer.writeln();
      buffer.writeln('=== إنتاج البيض ===');
      buffer.writeln('التاريخ,القطيع,كراتين,صحون,بيض سائب,إجمالي البيض');
      for (final e in eggs) {
        buffer.writeln(
            '${DateFormat('yyyy/MM/dd').format(e.date)},${e.flockId},${e.cartons},${e.trays},${e.looseEggs},${e.totalEggs}');
      }

      buffer.writeln();
      buffer.writeln('=== النفوق ===');
      buffer.writeln('التاريخ,القطيع,العدد,السبب');
      for (final m in mortality) {
        buffer.writeln(
            '${DateFormat('yyyy/MM/dd').format(m.date)},${m.flockId},${m.count},${m.reason.label}');
      }

      final dir = await _getBackupDir();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final csvFile = File(p.join(dir.path, 'madjana_export_$stamp.csv'));
      await csvFile.writeAsString(buffer.toString());

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم التصدير: ${p.basename(csvFile.path)}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('فشل التصدير: $e')));
    }
  }

  // ─────────────── إعادة تعيين البيانات ───────────────

  Future<void> _resetAllData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إعادة تعيين البيانات'),
        content: const Text(
            'هل تريد حذف جميع البيانات المحلية؟\n\nسيتم حذف:\n- جميع القطعان\n- جميع سجلات الإنتاج\n- جميع النفوقات\n- جميع المدفوعات\n- جميع النسخ الاحتياطية\n\nهذا الإجراء لا يمكن التراجع عنه!'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('حذف الكل'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final ok2 = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: const Text('هل أنت متأكد من حذف جميع البيانات؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('نعم، حذف الكل'),
          ),
        ],
      ),
    );
    if (ok2 != true) return;

    try {
      await LocalDatabase.close();
      final dbPath = await LocalDatabase.databasePath();
      final dbFile = File(dbPath);
      if (await dbFile.exists()) {
        await dbFile.delete();
      }

      final dir = await _getBackupDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }

      await LocalDatabase.database;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حذف جميع البيانات. أعد تشغيل التطبيق.')));
    } catch (e) {
      try { await LocalDatabase.database; } catch (_) {}
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
                    Text('عملة الإدخال',
                        style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 8),
                  const Text(
                      'اختر عملة الإدخال للقبض والمصروفات. العرض دائماً بالدولار (\$) وهو الأساسي.',
                      style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 16),
                  Material(
                    type: MaterialType.transparency,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment:
                          WrapCrossAlignment.center,
                      children: [
                        for (final c in AppCurrency.values)
                          ChoiceChip(
                            label:
                                Text('${c.label} (${c.symbol})'),
                            selected: _inputCurrency == c,
                            onSelected: (_) {
                              setState(
                                  () => _inputCurrency = c);
                              _saveInputCurrency();
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ─── إعدادات الحسابات ───
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.settings_outlined),
                    const SizedBox(width: 8),
                    Text('إعدادات الحسابات',
                        style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 16),
                  const Text(
                      'هذه الإعدادات تحدد وحدات القياس المستخدمة في الحسابات:',
                      style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 16),

                  _buildSettingField(
                    context,
                    icon: Icons.local_shipping_outlined,
                    label: 'وزن كيس العلف (كغ)',
                    initialValue: _feedBagWeightCtrl.text,
                    onChanged: (v) => setState(() => _feedBagWeightCtrl.text = v),
                    onSave: _saveFeedBagWeight,
                    isNumber: true,
                    suffix: 'كغ',
                  ),
                  const SizedBox(height: 12),

                  _buildSettingField(
                    context,
                    icon: Icons.inventory_2_outlined,
                    label: 'عدد البيض في الكرتون',
                    initialValue: _eggsPerCartonCtrl.text,
                    onChanged: (v) => setState(() => _eggsPerCartonCtrl.text = v),
                    onSave: _saveEggsPerCarton,
                    isNumber: true,
                  ),
                  const SizedBox(height: 12),

                  _buildSettingField(
                    context,
                    icon: Icons.grid_on_outlined,
                    label: 'عدد البيض في الصينية',
                    initialValue: _eggsPerTrayCtrl.text,
                    onChanged: (v) => setState(() => _eggsPerTrayCtrl.text = v),
                    onSave: _saveEggsPerTray,
                    isNumber: true,
                  ),
                  const SizedBox(height: 12),

                  _buildSettingField(
                    context,
                    icon: Icons.trending_down_outlined,
                    label: 'معدل النفوق الافتراضي (%)',
                    initialValue: _mortalityRateCtrl.text,
                    onChanged: (v) => setState(() => _mortalityRateCtrl.text = v),
                    onSave: _saveMortalityRate,
                    isNumber: true,
                    suffix: '%',
                  ),
                  const SizedBox(height: 12),

                  _buildSettingField(
                    context,
                    icon: Icons.warning_amber_outlined,
                    label: 'حد التنبيه لمخزون صحون الكرتون (صحن)',
                    initialValue: _cartonThresholdCtrl.text,
                    onChanged: (v) => setState(() => _cartonThresholdCtrl.text = v),
                    onSave: _saveCartonThreshold,
                    isNumber: true,
                    suffix: 'صحن',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ─── مظهر الواجهة ───
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.palette_outlined),
                    const SizedBox(width: 8),
                    Text('مظهر الواجهة',
                        style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 8),
                  const Text('اختر المظهر الأغمق للعمل الليلي أو الأفتح للنهار.',
                      style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 16),
                  Consumer(builder: (ctx, ref, _) {
                    final mode = ref.watch(themeModeProvider);
                    final notifier = ref.read(themeModeProvider.notifier);
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('نهاري'),
                          avatar: const Icon(Icons.light_mode, size: 18),
                          selected: mode == ThemeMode.light,
                          onSelected: (_) => notifier.setMode(ThemeMode.light),
                        ),
                        ChoiceChip(
                          label: const Text('ليلي'),
                          avatar: const Icon(Icons.dark_mode, size: 18),
                          selected: mode == ThemeMode.dark,
                          onSelected: (_) => notifier.setMode(ThemeMode.dark),
                        ),
                      ],
                    );
                  }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ─── إعدادات التنبيهات ───
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.notifications_outlined),
                    const SizedBox(width: 8),
                    Text('إعدادات التنبيهات',
                        style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('تنبيه المخزون المنخفض'),
                    subtitle: const Text('إشعار عند انخفاض مخزون صحون الكرتون',
                        style: TextStyle(color: Colors.grey, fontSize: 12)),
                    value: _lowStockAlert,
                    onChanged: (v) => setState(() => _lowStockAlert = v),
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    title: const Text('تنبيه النفوق'),
                    subtitle: const Text('إشعار عند تجاوز معدل النفوق للحد',
                        style: TextStyle(color: Colors.grey, fontSize: 12)),
                    value: _mortalityAlert,
                    onChanged: (v) => setState(() => _mortalityAlert = v),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ─── اللغة والعملة ───
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.language_outlined),
                    const SizedBox(width: 8),
                    Text('اللغة والعملة',
                        style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 12),
                  ListTile(
                    leading: const Icon(Icons.translate, size: 20),
                    title: const Text('اللغة'),
                    subtitle: Text(_selectedLanguage),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    contentPadding: EdgeInsets.zero,
                    onTap: () {},
                  ),
                  const Divider(),
                  _buildSettingField(
                    context,
                    icon: Icons.currency_exchange,
                    label: 'سعر الصرف (ليرة/دولار)',
                    initialValue: _exchangeRateCtrl.text,
                    onChanged: (v) => setState(() => _exchangeRateCtrl.text = v),
                    onSave: () {},
                    isNumber: true,
                    suffix: 'ل.س',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ─── إدارة المستخدمين (للمدير فقط) ───
          if (_canManageUsers) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.people_outlined),
                    const SizedBox(width: 8),
                    Text('إدارة المستخدمين',
                        style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 8),
                  ListTile(
                    leading: const Icon(Icons.person_add_outlined, size: 20),
                    title: const Text('إدارة المستخدمين'),
                    subtitle: const Text('إضافة وتعديل وحذف المستخدمين',
                        style: TextStyle(color: Colors.grey, fontSize: 12)),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    contentPadding: EdgeInsets.zero,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const UsersScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          ],
          const SizedBox(height: 16),

          // ─── النسخ الاحتياطي والاستعادة ───
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
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: _backupToCloud,
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('نسخ احتياطي سحابي (Supabase)'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: _exportDataAsCsv,
                    icon: const Icon(Icons.file_download_outlined),
                    label: const Text('تصدير البيانات كـ CSV'),
                  ),
                  const SizedBox(height: 8),
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
          const SizedBox(height: 16),

          // ─── إعادة تعيين البيانات ───
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.dangerous_outlined,
                        color: Colors.red.shade700),
                    const SizedBox(width: 8),
                    Text('منطقة الخطر',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(color: Colors.red.shade700)),
                  ]),
                  const SizedBox(height: 12),
                  ListTile(
                    leading: Icon(Icons.restore_from_trash_outlined,
                        color: Colors.red.shade700, size: 20),
                    title: Text('إعادة تعيين البيانات',
                        style: TextStyle(color: Colors.red.shade700)),
                    subtitle: const Text('حذف جميع البيانات المحلية',
                        style: TextStyle(color: Colors.grey, fontSize: 12)),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    contentPadding: EdgeInsets.zero,
                    onTap: _resetAllData,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ─── حول التطبيق ───
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.info_outline),
                    const SizedBox(width: 8),
                    Text('حول التطبيق',
                        style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 12),
                  const ListTile(
                    leading: Icon(Icons.agriculture, size: 32, color: Colors.green),
                    title: Text('مُدجّنة',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                    subtitle: Text('نظام إدارة المداجن الذكي',
                        style: TextStyle(color: Colors.grey)),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const Divider(),
                  const _AboutRow('الإصدار', '1.0.0'),
                  const _AboutRow('المطور', 'YAseen Farm'),
                  const _AboutRow('البريد', 'support@yaseenfarm.com'),
                  const _AboutRow('الرخصة', 'مغلق المصدر'),
                  const SizedBox(height: 8),
                  Text(
                    'تطبيق مُدجّنة لإدارة المداجن الشامل. يدعم التسجيل اليومي للإنتاج والنفوق والعلف، '
                    'مع مزامنة سحابية وتحليلات ذكية.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSettingField(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String initialValue,
    required ValueChanged<String> onChanged,
    required VoidCallback onSave,
    bool isNumber = false,
    String suffix = '',
  }) {
    final ctrl = TextEditingController(text: initialValue);
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.grey[600]),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 14)),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 120,
          child: TextField(
            controller: ctrl,
            keyboardType: isNumber ? TextInputType.number : TextInputType.text,
            textAlign: TextAlign.right,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              suffixText: suffix.isNotEmpty ? suffix : null,
              border: const OutlineInputBorder(),
            ),
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.save_outlined, size: 20),
          onPressed: onSave,
          tooltip: 'حفظ',
        ),
      ],
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;
  const _AboutRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }
}
