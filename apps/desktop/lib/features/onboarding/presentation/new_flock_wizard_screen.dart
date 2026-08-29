import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'package:uuid/uuid.dart';
import '../../../core/providers.dart';
import '../../../core/shell_state.dart';
import '../../auth/providers/auth_provider.dart';

/// معالج فوج جديد - إنشاء قطيع جديد مع ربط العامل المسؤول
///
/// خطوتان:
/// 1. بيانات القطيع (العدد الأولي، عدد العنابر، الاسم/السلالة، اسم المدجنة)
/// 2. العامل المسؤول (اسم العامل + إنشاء حساب جديد له إن لم يوجد)
class NewFlockWizardScreen extends ConsumerStatefulWidget {
  const NewFlockWizardScreen({super.key});

  @override
  ConsumerState<NewFlockWizardScreen> createState() =>
      _NewFlockWizardScreenState();
}

class _NewFlockWizardScreenState extends ConsumerState<NewFlockWizardScreen> {
  final _uuid = const Uuid();

  // بيانات القطيع
  late final TextEditingController _breedCtrl;
  late final TextEditingController _initialBirdsCtrl;
  late final TextEditingController _farmNameCtrl;
  int _sectionsCount = 1;
  DateTime _startDate = DateTime.now();

  // العامل المسؤول
  late final TextEditingController _workerNameCtrl;
  late final TextEditingController _workerPhoneCtrl;
  late final TextEditingController _workerPinCtrl;

  List<UserModel> _workers = [];
  String? _selectedWorkerId;
  bool _createNewWorker = true;
  bool _loadingWorkers = true;

  int _step = 0;
  bool _saving = false;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _breedCtrl = TextEditingController();
    _initialBirdsCtrl = TextEditingController();
    _farmNameCtrl = TextEditingController();
    _workerNameCtrl = TextEditingController();
    _workerPhoneCtrl = TextEditingController();
    _workerPinCtrl = TextEditingController();
    _loadFarmAndWorkers();
  }

  Future<void> _loadFarmAndWorkers() async {
    try {
      final farm = await ref.read(farmRepositoryProvider).getFarm(_farmId);
      _farmNameCtrl.text = farm.name;
    } catch (_) {}
    try {
      final users = await ref.read(userAdminRepositoryProvider).getUsers(_farmId);
      _workers = users
          .where((u) => u.role == UserRole.worker || u.role == UserRole.supervisor)
          .toList();
    } catch (_) {
      _workers = [];
    }
    if (mounted) setState(() => _loadingWorkers = false);
  }

  @override
  void dispose() {
    _breedCtrl.dispose();
    _initialBirdsCtrl.dispose();
    _farmNameCtrl.dispose();
    _workerNameCtrl.dispose();
    _workerPhoneCtrl.dispose();
    _workerPinCtrl.dispose();
    super.dispose();
  }

  int _toInt(TextEditingController c) => int.tryParse(c.text) ?? 0;

  bool _validateStep() {
    if (_step == 0) {
      if (_breedCtrl.text.trim().isEmpty) {
        _showSnack('أدخل اسم القطيع / السلالة');
        return false;
      }
      if (_toInt(_initialBirdsCtrl) <= 0) {
        _showSnack('أدخل العدد الأولي للدجاج');
        return false;
      }
      if (_farmNameCtrl.text.trim().isEmpty) {
        _showSnack('أدخل اسم المدجنة');
        return false;
      }
    }
    if (_step == 1) {
      if (_createNewWorker) {
        if (_workerNameCtrl.text.trim().isEmpty) {
          _showSnack('أدخل اسم العامل المسؤول');
          return false;
        }
        if (_workerPhoneCtrl.text.trim().length < 8) {
          _showSnack('أدخل رقم هاتف صحيح للعامل');
          return false;
        }
        if (_workerPinCtrl.text.trim().length < 4) {
          _showSnack('الرقم السري لا يقل عن 4 أرقام');
          return false;
        }
      } else if (_selectedWorkerId == null) {
        _showSnack('اختر العامل المسؤول');
        return false;
      }
    }
    return true;
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    if (!_validateStep()) return;
    setState(() => _saving = true);
    try {
      final flockId = _uuid.v4();

      // 1. تحديث اسم المدجنة إن تغيّر
      try {
        final farm = await ref.read(farmRepositoryProvider).getFarm(_farmId);
        if (farm.name != _farmNameCtrl.text.trim()) {
          await ref.read(farmRepositoryProvider).updateFarm(FarmModel(
                id: _farmId,
                name: _farmNameCtrl.text.trim(),
                location: farm.location,
                ownerId: farm.ownerId,
              ));
        }
      } catch (_) {}

      // 2. إنشاء القطيع
      final initialBirds = _toInt(_initialBirdsCtrl);
      await ref.read(flockRepositoryProvider).createFlock(FlockModel(
            id: flockId,
            farmId: _farmId,
            breed: _breedCtrl.text.trim(),
            startDate: _startDate,
            initialCount: initialBirds,
            currentCount: initialBirds,
            status: FlockStatus.active,
            sectionsCount: _sectionsCount,
          ));

      // 3. إنشاء حساب العامل إن لم يوجد
      if (_createNewWorker) {
        await ref.read(userAdminRepositoryProvider).createUser(
              farmId: _farmId,
              name: _workerNameCtrl.text.trim(),
              phone: _workerPhoneCtrl.text.trim(),
              pin: _workerPinCtrl.text.trim(),
              role: UserRole.worker,
            );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم إنشاء الفوج الجديد بنجاح')),
      );
      ref.read(dataRefreshTickProvider.notifier).state++;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showSnack('فشل الحفظ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('معالج فوج جديد')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStepper(),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(child: _buildStepContent()),
            ),
            const SizedBox(height: 8),
            _buildNavButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildStepper() {
    const steps = ['بيانات القطيع', 'العامل المسؤول'];
    return Row(
      children: List.generate(steps.length, (i) {
        final active = i == _step;
        final done = i < _step;
        return Expanded(
          child: Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: active
                        ? Theme.of(context).colorScheme.primary
                        : done
                            ? Colors.green.shade100
                            : Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        done ? Icons.check : Icons.circle_outlined,
                        size: 16,
                        color: active
                            ? Colors.white
                            : done
                                ? Colors.green
                                : Colors.grey,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        steps[i],
                        style: TextStyle(
                          color: active ? Colors.white : null,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (i < steps.length - 1) const SizedBox(width: 8),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildStepContent() {
    return _step == 0 ? _buildFlockInfo() : _buildWorker();
  }

  Widget _buildFlockInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('بيانات القطيع الجديد',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        TextField(
          controller: _breedCtrl,
          decoration: const InputDecoration(
            labelText: 'اسم / سلالة القطيع',
            hintText: 'مثال: هاي لاين بروان',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _farmNameCtrl,
          decoration: const InputDecoration(
            labelText: 'اسم المدجنة',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        InkWell(
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: _startDate,
              firstDate: DateTime(2020),
              lastDate: DateTime.now(),
            );
            if (d != null) setState(() => _startDate = d);
          },
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'تاريخ بدء الدورة',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.calendar_today),
            ),
            child: Text(Formatters.formatDate(_startDate)),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _initialBirdsCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'العدد الأولي للدجاج',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          value: _sectionsCount,
          decoration: const InputDecoration(
            labelText: 'عدد العنابر',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 1, child: Text('عنبر واحد')),
            DropdownMenuItem(value: 2, child: Text('عنبران')),
            DropdownMenuItem(value: 3, child: Text('3 عنابر')),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _sectionsCount = v);
          },
        ),
      ],
    );
  }

  Widget _buildWorker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('العامل المسؤول عن القطيع',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        if (_loadingWorkers)
          const Center(child: CircularProgressIndicator())
        else if (_workers.isNotEmpty) ...[
          RadioListTile<String>(
            title: const Text('اختيار عامل موجود'),
            value: 'existing',
            groupValue: _createNewWorker ? 'new' : 'existing',
            onChanged: (v) => setState(() {
              _createNewWorker = false;
              _selectedWorkerId =
                  _workers.isNotEmpty ? _workers.first.uid : null;
            }),
          ),
          if (!_createNewWorker)
            DropdownButtonFormField<String>(
              value: _selectedWorkerId,
              decoration: const InputDecoration(
                labelText: 'العامل',
                border: OutlineInputBorder(),
              ),
              items: _workers
                  .map((w) => DropdownMenuItem(
                      value: w.uid,
                      child: Text('${w.name} — ${w.role.label}')))
                  .toList(),
              onChanged: (v) => setState(() => _selectedWorkerId = v),
            ),
          const Divider(height: 24),
        ],
        RadioListTile<String>(
          title: const Text('إنشاء حساب جديد للعامل'),
          value: 'new',
          groupValue: _createNewWorker ? 'new' : 'existing',
          onChanged: (v) => setState(() => _createNewWorker = true),
        ),
        if (_createNewWorker) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _workerNameCtrl,
            decoration: const InputDecoration(
              labelText: 'اسم العامل',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _workerPhoneCtrl,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'رقم الهاتف',
              hintText: 'مثال: 0934123456',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _workerPinCtrl,
            keyboardType: TextInputType.number,
            obscureText: true,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'الرقم السري (4 أرقام فأكثر)',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNavButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (_step > 0)
          OutlinedButton.icon(
            onPressed: _saving
                ? null
                : () => setState(() => _step--),
            icon: const Icon(Icons.arrow_back),
            label: const Text('السابق'),
          )
        else
          OutlinedButton.icon(
            onPressed: _saving ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close),
            label: const Text('إلغاء'),
          ),
        _step == 0
            ? FilledButton.icon(
                onPressed: _saving
                    ? null
                    : () {
                        if (!_validateStep()) return;
                        setState(() => _step++);
                      },
                icon: const Icon(Icons.arrow_forward),
                label: const Text('التالي'),
              )
            : FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(_saving ? 'جارٍ الإنشاء...' : 'إنشاء الفوج'),
              ),
      ],
    );
  }
}