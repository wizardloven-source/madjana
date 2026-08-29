import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'package:uuid/uuid.dart';
import '../../../core/providers.dart';
import '../../../core/shell_state.dart';
import '../../auth/providers/auth_provider.dart';

/// معالج قطيع قديم - إدخال الأرصدة الافتتاحية لقطيع يعمل قبل النظام
///
/// مكون من خطوتين:
/// 1. بيانات القطيع (اسم/سلالة، تاريخ البدء، عدد العنابر، العدد الأولي)
/// 2. الأرصدة الافتتاحية (إنتاج البيض، التخريج، العلف، النفوق، المدفوعات، الإيرادات)
/// 3. تفصيل العنابر (كل عنبر: العدد الأولي + النفوق)
class OldFlockWizardScreen extends ConsumerStatefulWidget {
  const OldFlockWizardScreen({super.key});

  @override
  ConsumerState<OldFlockWizardScreen> createState() =>
      _OldFlockWizardScreenState();
}

class _OldFlockWizardScreenState extends ConsumerState<OldFlockWizardScreen> {
  final _uuid = const Uuid();

  // بيانات القطيع
  late final TextEditingController _breedCtrl;
  late final TextEditingController _startCtrl;
  DateTime _startDate = DateTime.now().subtract(const Duration(days: 273));
  int _sectionsCount = 1;

  // الأرصدة الكلية
  late final TextEditingController _eggsProducedCtrl;
  late final TextEditingController _eggsDispatchedCtrl;
  late final TextEditingController _feedConsumedCtrl;
  late final TextEditingController _initialBirdsCtrl;
  late final TextEditingController _mortalityCtrl;
  late final TextEditingController _paymentsCtrl;
  late final TextEditingController _revenuesCtrl;

  // تفصيل العنابر
  final List<TextEditingController> _sectionInitial = [];
  final List<TextEditingController> _sectionMortality = [];

  int _step = 0;
  bool _saving = false;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    _breedCtrl = TextEditingController();
    _startCtrl = TextEditingController();
    _eggsProducedCtrl = TextEditingController();
    _eggsDispatchedCtrl = TextEditingController();
    _feedConsumedCtrl = TextEditingController();
    _initialBirdsCtrl = TextEditingController();
    _mortalityCtrl = TextEditingController();
    _paymentsCtrl = TextEditingController();
    _revenuesCtrl = TextEditingController();
    _syncSections();
  }

  void _syncSections() {
    while (_sectionInitial.length < _sectionsCount) {
      _sectionInitial.add(TextEditingController());
      _sectionMortality.add(TextEditingController());
    }
    while (_sectionInitial.length > _sectionsCount) {
      _sectionInitial.removeLast().dispose();
      _sectionMortality.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    _breedCtrl.dispose();
    _startCtrl.dispose();
    _eggsProducedCtrl.dispose();
    _eggsDispatchedCtrl.dispose();
    _feedConsumedCtrl.dispose();
    _initialBirdsCtrl.dispose();
    _mortalityCtrl.dispose();
    _paymentsCtrl.dispose();
    _revenuesCtrl.dispose();
    for (final c in _sectionInitial) {
      c.dispose();
    }
    for (final c in _sectionMortality) {
      c.dispose();
    }
    super.dispose();
  }

  int _toInt(TextEditingController c) => int.tryParse(c.text) ?? 0;
  double _toDouble(TextEditingController c) => double.tryParse(c.text) ?? 0;

  bool _validateStep() {
    if (_step == 0) {
      if (_breedCtrl.text.trim().isEmpty) {
        _showSnack('أدخل اسم أو سلالة القطيع');
        return false;
      }
      if (_toInt(_initialBirdsCtrl) <= 0) {
        _showSnack('أدخل عدد الدجاج الأولي');
        return false;
      }
    }
    if (_step == 1) {
      if (_toInt(_eggsProducedCtrl) <= 0 &&
          _toInt(_eggsDispatchedCtrl) <= 0 &&
          _toDouble(_feedConsumedCtrl) <= 0 &&
          _toInt(_mortalityCtrl) <= 0 &&
          _toDouble(_paymentsCtrl) <= 0 &&
          _toDouble(_revenuesCtrl) <= 0) {
        _showSnack('أدخل بيانات دفعة واحدة على الأقل أو تخطَّ هذه الخطوة');
        return false;
      }
    }
    return true;
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    if (!_validateStep()) return;
    setState(() => _saving = true);
    try {
      final flockId = _uuid.v4();
      final initialBirds = _toInt(_initialBirdsCtrl);

      // 1. إنشاء القطيع مع العدد الحالي = الأولي - النفوق
      final flock = FlockModel(
        id: flockId,
        farmId: _farmId,
        breed: _breedCtrl.text.trim(),
        startDate: _startDate,
        initialCount: initialBirds,
        currentCount: (initialBirds - _toInt(_mortalityCtrl)).clamp(0, initialBirds),
        status: FlockStatus.active,
        sectionsCount: _sectionsCount,
      );
      await ref.read(flockRepositoryProvider).createFlock(flock);

      // 2. تفصيل العنابر
      final sections = <OpeningSectionModel>[];
      for (var i = 0; i < _sectionsCount; i++) {
        final initial = _toInt(_sectionInitial[i]);
        if (initial <= 0) continue;
        sections.add(OpeningSectionModel(
          sectionNo: i + 1,
          initialBirds: initial,
          mortalityCount: _toInt(_sectionMortality[i]),
        ));
      }

      // 3. حفظ الأرصدة الافتتاحية
      final balance = OpeningBalanceModel(
        id: flockId,
        farmId: _farmId,
        flockId: flockId,
        createdAt: _startDate,
        eggsProduced: _toInt(_eggsProducedCtrl),
        eggsDispatched: _toInt(_eggsDispatchedCtrl),
        feedConsumedKg: _toDouble(_feedConsumedCtrl),
        initialBirds: initialBirds,
        mortalityCount: _toInt(_mortalityCtrl),
        totalPayments: _toDouble(_paymentsCtrl),
        totalRevenues: _toDouble(_revenuesCtrl),
        sections: sections,
      );
      await ref.read(openingBalanceRepositoryProvider).save(balance);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ القطيع القديم والأرصدة بنجاح')),
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
      appBar: AppBar(title: const Text('معالج قطيع قديم — الأرصدة الافتتاحية')),
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
    const steps = ['بيانات القطيع', 'الأرصدة الكلية', 'تفصيل العنابر'];
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
    switch (_step) {
      case 0:
        return _buildFlockInfo();
      case 1:
        return _buildBalances();
      default:
        return _buildSections();
    }
  }

  Widget _buildFlockInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('بيانات القطيع القديم',
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
            labelText: 'عدد الدجاج الأولي عند بدء الدورة',
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
            if (v == null) return;
            setState(() {
              _sectionsCount = v;
              _syncSections();
            });
          },
        ),
      ],
    );
  }

  Widget _moneyField(TextEditingController ctrl, String label) {
    return TextField(
      controller: ctrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _intField(TextEditingController ctrl, String label) {
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _buildBalances() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('الأرصدة الافتتاحية (حتى اليوم)',
            style: Theme.of(context).textTheme.titleLarge),
        const Text('أدخل الإجمالي المتراكم منذ بدء الدورة حتى الآن.',
            style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 16),
        _intField(_eggsProducedCtrl, 'كمية البيض المُنتجة حتى الآن (بيضة)'),
        const SizedBox(height: 16),
        _intField(_eggsDispatchedCtrl, 'كمية البيض المُخرَّج حتى الآن (بيضة)'),
        const SizedBox(height: 16),
        _moneyField(_feedConsumedCtrl, 'كمية العلف المستهلك حتى الآن (كغ)'),
        const SizedBox(height: 16),
        _intField(_mortalityCtrl, 'كمية النفوق حتى الآن'),
        const SizedBox(height: 16),
        _moneyField(_paymentsCtrl, 'إجمالي المدفوعات المصروفة حتى الآن'),
        const SizedBox(height: 16),
        _moneyField(_revenuesCtrl, 'إجمالي الإيرادات المحصَّلة حتى الآن'),
      ],
    );
  }

  Widget _buildSections() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('تفصيل العنابر', style: Theme.of(context).textTheme.titleLarge),
        const Text('أدخل عدد الدجاج الأولي والنفوق في كل عنبر.',
            style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 16),
        for (var i = 0; i < _sectionsCount; i++) ...[
          Text('العنبر ${i + 1}',
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _intField(_sectionInitial[i], 'العدد الأولي بالعنبر'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _intField(_sectionMortality[i], 'النفوق بالعنبر'),
              ),
            ],
          ),
          const SizedBox(height: 16),
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
            onPressed: _saving
                ? null
                : () => Navigator.pop(context),
            icon: const Icon(Icons.close),
            label: const Text('إلغاء'),
          ),
        _step < 2
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
                label: Text(_saving ? 'جارٍ الحفظ...' : 'حفظ القطيع القديم'),
              ),
      ],
    );
  }
}