import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../shared/widgets/date_picker_field.dart';
import '../../../shared/widgets/modern_ui.dart';
import '../../auth/providers/auth_provider.dart';
import '../../reference_data/providers/reference_data_provider.dart';
import '../providers/medications_provider.dart';

class MedicationsScreen extends ConsumerStatefulWidget {
  const MedicationsScreen({super.key});

  @override
  ConsumerState<MedicationsScreen> createState() => _MedicationsScreenState();
}

class _MedicationsScreenState extends ConsumerState<MedicationsScreen> {
  DateTime _selectedDate = DateTime.now();
  String? _selectedFarmId;
  MedicationType? _selectedType;
  String? _selectedMedicineId;
  final _dosageController = TextEditingController();
  AdministrationRoute? _selectedRoute;
  int? _treatmentDays;

  final _notesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = ref.read(authProvider).currentUser;
      if (user?.farmId != null) {
        setState(() => _selectedFarmId = user!.farmId);
      }
    });
  }

  @override
  void dispose() {
    _dosageController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_selectedFarmId == null) {
      _showError('اختر المدجنة');
      return;
    }
    if (_selectedType == null) {
      _showError('اختر نوع الإجراء');
      return;
    }
    if (_selectedMedicineId == null) {
      _showError('اختر الدواء');
      return;
    }
    if (_dosageController.text.isEmpty) {
      _showError('أدخل الجرعة');
      return;
    }
    if (_selectedRoute == null) {
      _showError('اختر طريق الإعطاء');
      return;
    }

    final user = ref.read(authProvider).currentUser;
    if (user == null || user.farmId == null) {
      _showError('خطأ في بيانات المستخدم');
      return;
    }
    final medicines =
        ref.read(medicinesCatalogProvider).value ?? const <MedicineModel>[];
    final selectedMedicine = medicines.firstWhere(
      (m) => m.id == _selectedMedicineId,
      orElse: () => medicines.isNotEmpty ? medicines.first : MedicineModel(id: '', name: '', type: MedicationType.drug),
    );

    final result = await ref.read(medicationsProvider.notifier).save(
          farmId: user.farmId!,
          date: _selectedDate,
          type: _selectedType!,
          medicineName: selectedMedicine.name,
          dosage: _dosageController.text,
          route: _selectedRoute!,
          treatmentDays: _treatmentDays,
          withdrawalDays: selectedMedicine.withdrawalDays,
          notes: _notesController.text.isEmpty ? null : _notesController.text,
          workerId: user.uid,
        );

    if (result.success) {
      if (selectedMedicine.withdrawalDays > 0) {
        _showWithdrawalWarning(selectedMedicine.withdrawalDays);
      } else {
        _showSuccess('تم الحفظ بنجاح');
      }
      _clearFields();
    } else {
      _showError(result.error ?? 'فشل الحفظ');
    }
  }

  void _showWithdrawalWarning(int days) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(AppConstants.colorDanger),
        title: const Row(
          children: [
            Icon(Icons.warning, color: Colors.white),
            SizedBox(width: 8),
            Text('تنبيه فترة السحب', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Text(
          'لا يُسمح ببيع البيض لمدة $days يوم\n'
          'من تاريخ: ${Formatters.formatDate(_selectedDate)}',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showSuccess('تم الحفظ بنجاح');
            },
            child: const Text('حسناً', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _clearFields() {
    setState(() {
      _selectedType = null;
      _selectedMedicineId = null;
      _selectedRoute = null;
      _treatmentDays = null;
      _dosageController.clear();
      _notesController.clear();
    });
  }

  void _showError(String message) => AppSnack.error(context, message);

  void _showSuccess(String message) => AppSnack.success(context, message);

  @override
  Widget build(BuildContext context) {
    final medicinesAsync = ref.watch(medicinesCatalogProvider);
    final medicines = medicinesAsync.value ?? const <MedicineModel>[];

    final filteredMedicines = _selectedType != null
        ? medicines.where((m) => m.type == _selectedType).toList()
        : medicines;

    return Scaffold(
      appBar: AppBar(title: const Text('الأدوية')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DatePickerField(
              value: _selectedDate,
              label: 'التاريخ',
              onChanged: (date) => setState(() => _selectedDate = date),
            ),
            const SizedBox(height: 16),

            DropdownButtonFormField<MedicationType>(
              initialValue: _selectedType,
              decoration: const InputDecoration(labelText: 'نوع الإجراء'),
              items: MedicationType.values.map((type) {
                final label = switch (type) {
                  MedicationType.drug => 'دواء',
                  MedicationType.vaccine => 'لقاح',
                  MedicationType.vitamin => 'فيتامين',
                };
                return DropdownMenuItem(value: type, child: Text(label));
              }).toList(),
              onChanged: (v) => setState(() {
                _selectedType = v;
                _selectedMedicineId = null;
              }),
            ),
            const SizedBox(height: 16),

            DropdownButtonFormField<String>(
              initialValue: _selectedMedicineId,
              decoration: const InputDecoration(labelText: 'اسم الدواء (مع بحث)'),
              items: filteredMedicines.map((m) {
                return DropdownMenuItem(
                  value: m.id,
                  child: Row(
                    children: [
                      Expanded(child: Text(m.name)),
                      if (m.withdrawalDays > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(AppConstants.colorDanger),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${m.withdrawalDays} يوم سحب',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }).toList(),
              onChanged: (v) => setState(() => _selectedMedicineId = v),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _dosageController,
              decoration: const InputDecoration(labelText: 'الجرعة'),
            ),
            const SizedBox(height: 16),

            DropdownButtonFormField<AdministrationRoute>(
              initialValue: _selectedRoute,
              decoration: const InputDecoration(labelText: 'طريقة الإعطاء'),
              items: AdministrationRoute.values.map((route) {
                final label = switch (route) {
                  AdministrationRoute.water => 'ماء الشرب',
                  AdministrationRoute.spray => 'رش',
                  AdministrationRoute.injection => 'حقن',
                  AdministrationRoute.feed => 'في العلف',
                };
                return DropdownMenuItem(value: route, child: Text(label));
              }).toList(),
              onChanged: (v) => setState(() => _selectedRoute = v),
            ),
            const SizedBox(height: 16),

            TextField(
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'مدة العلاج (أيام)'),
              onChanged: (v) {
                _treatmentDays = int.tryParse(v);
              },
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _notesController,
              decoration: const InputDecoration(labelText: 'ملاحظات'),
              maxLines: 2,
            ),
            const SizedBox(height: 24),

            PrimaryActionButton(
              label: 'حفظ',
              onPressed: _save,
              color: Colors.purple,
            ),
          ],
        ),
      ),
    );
  }
}
