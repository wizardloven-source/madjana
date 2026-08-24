import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../shared/widgets/date_picker_field.dart';
import '../../../shared/widgets/modern_ui.dart';
import '../../auth/providers/auth_provider.dart';
import '../../reference_data/providers/reference_data_provider.dart';
import '../providers/medications_provider.dart';

/// ط´ط§ط´ط© ط§ظ„ط£ط¯ظˆظٹط©
/// 
/// ط§ظ„ظ…ظ…ظٹط²ط§طھ:
/// - ظ‚ط§ط¦ظ…ط© ط§ظ„ط£ط¯ظˆظٹط© ظ…ظ† medicines_catalog
/// - طھط­ط°ظٹط± ظپطھط±ط© ط§ظ„ط³ط­ط¨ (withdrawal_days)
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
      _showError('ط§ط®طھط± ط§ظ„ظ…ط¯ط¬ظ†ط©');
      return;
    }
    if (_selectedType == null) {
      _showError('ط§ط®طھط± ظ†ظˆط¹ ط§ظ„ط¥ط¬ط±ط§ط،');
      return;
    }
    if (_selectedMedicineId == null) {
      _showError('ط§ط®طھط± ط§ظ„ط¯ظˆط§ط،');
      return;
    }
    if (_dosageController.text.isEmpty) {
      _showError('ط£ط¯ط®ظ„ ط§ظ„ط¬ط±ط¹ط©');
      return;
    }
    if (_selectedRoute == null) {
      _showError('ط§ط®طھط± ط·ط±ظٹظ‚ط© ط§ظ„ط¥ط¹ط·ط§ط،');
      return;
    }

    final user = ref.read(authProvider).currentUser!;
    final medicines =
        ref.read(medicinesCatalogProvider).value ?? const <MedicineModel>[];
    final selectedMedicine = medicines.firstWhere(
      (m) => m.id == _selectedMedicineId,
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
      // طھط­ط°ظٹط± ظپطھط±ط© ط§ظ„ط³ط­ط¨
      if (selectedMedicine.withdrawalDays > 0) {
        _showWithdrawalWarning(selectedMedicine.withdrawalDays);
      } else {
        _showSuccess('طھظ… ط§ظ„ط­ظپط¸ ط¨ظ†ط¬ط§ط­');
      }
      _clearFields();
    } else {
      _showError(result.error ?? 'ظپط´ظ„ ط§ظ„ط­ظپط¸');
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
            Text('طھظ†ط¨ظٹظ‡ ظپطھط±ط© ط§ظ„ط³ط­ط¨', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Text(
          'ظ„ط§ ظٹظڈط³ظ…ط­ ط¨ط¨ظٹط¹ ط§ظ„ط¨ظٹط¶ ظ„ظ…ط¯ط© $days ظٹظˆظ…\n'
          'ظ…ظ† طھط§ط±ظٹط®: ${Formatters.formatDate(_selectedDate)}',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showSuccess('طھظ… ط§ظ„ط­ظپط¸ ط¨ظ†ط¬ط§ط­');
            },
            child: const Text('ط­ط³ظ†ط§ظ‹', style: TextStyle(color: Colors.white)),
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

    // ظپظ„طھط±ط© ط§ظ„ط£ط¯ظˆظٹط© ط­ط³ط¨ ط§ظ„ظ†ظˆط¹ ط§ظ„ظ…ط®طھط§ط±
    final filteredMedicines = _selectedType != null
        ? medicines.where((m) => m.type == _selectedType).toList()
        : medicines;

    return Scaffold(
      appBar: AppBar(title: const Text('ط§ظ„ط£ط¯ظˆظٹط©')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ط§ظ„طھط§ط±ظٹط®
            DatePickerField(
              value: _selectedDate,
              label: 'ط§ظ„طھط§ط±ظٹط®',
              onChanged: (date) => setState(() => _selectedDate = date),
            ),
            const SizedBox(height: 16),

            // ظ†ظˆط¹ ط§ظ„ط¥ط¬ط±ط§ط،
            DropdownButtonFormField<MedicationType>(
              initialValue: _selectedType,
              decoration: const InputDecoration(labelText: ''),
              items: MedicationType.values.map((type) {
                final label = switch (type) {
                  MedicationType.drug => 'ط¯ظˆط§ط،',
                  MedicationType.vaccine => 'ظ„ظ‚ط§ط­',
                  MedicationType.vitamin => 'ظپظٹطھط§ظ…ظٹظ†',
                };
                return DropdownMenuItem(value: type, child: Text(label));
              }).toList(),
              onChanged: (v) => setState(() {
                _selectedType = v;
                _selectedMedicineId = null; // ط¥ط¹ط§ط¯ط© طھط¹ظٹظٹظ†
              }),
            ),
            const SizedBox(height: 16),

            // ط§ط³ظ… ط§ظ„ط¯ظˆط§ط، (ظ…ط¹ ط¨ط­ط«)
            DropdownButtonFormField<String>(
              initialValue: _selectedMedicineId,
              decoration: const InputDecoration(labelText: ''),
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
                            '${m.withdrawalDays} ظٹظˆظ… ط³ط­ط¨',
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

            // ط§ظ„ط¬ط±ط¹ط©
            TextField(
              controller: _dosageController,
              decoration: const InputDecoration(labelText: ''),
            ),
            const SizedBox(height: 16),

            // ط·ط±ظٹظ‚ط© ط§ظ„ط¥ط¹ط·ط§ط،
            DropdownButtonFormField<AdministrationRoute>(
              initialValue: _selectedRoute,
              decoration: const InputDecoration(labelText: ''),
              items: AdministrationRoute.values.map((route) {
                final label = switch (route) {
                  AdministrationRoute.water => 'ظ…ط§ط، ط§ظ„ط´ط±ط¨',
                  AdministrationRoute.spray => 'ط±ط´',
                  AdministrationRoute.injection => 'ط­ظ‚ظ†',
                  AdministrationRoute.feed => 'ظپظٹ ط§ظ„ط¹ظ„ظپ',
                };
                return DropdownMenuItem(value: route, child: Text(label));
              }).toList(),
              onChanged: (v) => setState(() => _selectedRoute = v),
            ),
            const SizedBox(height: 16),

            // ظ…ط¯ط© ط§ظ„ط¹ظ„ط§ط¬
            TextField(
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: ''),
              onChanged: (v) {
                _treatmentDays = int.tryParse(v);
              },
            ),
            const SizedBox(height: 16),

            // ظ…ظ„ط§ط­ط¸ط§طھ
            TextField(
              controller: _notesController,
              decoration: const InputDecoration(labelText: ''),
              maxLines: 2,
            ),
            const SizedBox(height: 24),

            // ط²ط± ط§ظ„ط­ظپط¸
            PrimaryActionButton(
              label: 'ط­ظپط¸',
              onPressed: _save,
              color: Colors.purple,
            ),
          ],
        ),
      ),
    );
  }
}