import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// مركز العمليات الموحد للمدير
/// يسمح بإدخال أي نوع من البيانات لأي مزرعة من مكان واحد
class OperationsHub extends ConsumerStatefulWidget {
  const OperationsHub({Key? key}) : super(key: key);

  @override
  ConsumerState<OperationsHub> createState() => _OperationsHubState();
}

class _OperationsHubState extends ConsumerState<OperationsHub> with SingleTickerProviderStateMixin {
  String? _selectedFarmId;
  String? _selectedFlockId;
  late TabController _tabController;

  final List<Tab> _tabs = [
    const Tab(text: '🥚 إنتاج البيض', icon: Icon(Icons鸡蛋)),
    const Tab(text: '💀 النفوق', icon: Icon(Icons.warning)),
    const Tab(text: '🌾 العلف', icon: Icon(Icons.grain)),
    const Tab(text: '💊 الأدوية', icon: Icon(Icons.medication)),
    const Tab(text: '📤 التخريج', icon: Icon(Icons.local_shipping)),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مركز العمليات'),
        bottom: TabBar(
          controller: _tabController,
          tabs: _tabs,
          isScrollable: true,
          labelColor: Theme.of(context).primaryColor,
          unselectedLabelColor: Colors.grey,
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) => setState(() => _selectedFarmId = value),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'farm1', child: Text('مزرعة الأمل')),
              const PopupMenuItem(value: 'farm2', child: Text('مزرعة البركة')),
              const PopupMenuItem(value: 'farm3', child: Text('مزرعة النور')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.business),
                  const SizedBox(width: 8),
                  Text(_selectedFarmId ?? 'اختر مزرعة'),
                ],
              ),
            ),
          ),
        ],
      ),
      body: _selectedFarmId == null
          ? _buildEmptyState()
          : TabBarView(
              controller: _tabController,
              children: [
                EggProductionForm(farmId: _selectedFarmId!, flockId: _selectedFlockId),
                MortalityForm(farmId: _selectedFarmId!, flockId: _selectedFlockId),
                FeedForms(farmId: _selectedFarmId!, flockId: _selectedFlockId),
                MedicationForm(farmId: _selectedFarmId!, flockId: _selectedFlockId),
                DispatchForm(farmId: _selectedFarmId!, flockId: _selectedFlockId),
              ],
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.business_outlined, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 24),
          Text(
            'الرجاء اختيار مزرعة للبدء',
            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          Text(
            'يمكنك اختيار المزرعة من القائمة في الأعلى',
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }
}

// نماذج الإدخال لكل عملية
class EggProductionForm extends StatelessWidget {
  final String farmId;
  final String? flockId;

  const EggProductionForm({Key? key, required this.farmId, this.flockId}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('تسجيل إنتاج البيض', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'القطيع', border: OutlineInputBorder()),
                items: [const DropdownMenuItem(value: 'flock1', child: Text('قطيع أ-1'))],
                onChanged: (value) {},
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(labelText: 'عدد الكرتون', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(labelText: 'عدد الصواني', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(labelText: 'حبات فردية', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.save),
                label: const Text('حفظ السجل'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MortalityForm extends StatelessWidget {
  final String farmId;
  final String? flockId;

  const MortalityForm({Key? key, required this.farmId, this.flockId}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('تسجيل النفوق', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'القطيع', border: OutlineInputBorder()),
                items: [const DropdownMenuItem(value: 'flock1', child: Text('قطيع أ-1'))],
                onChanged: (value) {},
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(labelText: 'عدد الطيور النافقة', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'سبب النفوق', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'disease', child: Text('مرض')),
                  DropdownMenuItem(value: 'accident', child: Text('حادث')),
                  DropdownMenuItem(value: 'unknown', child: Text('سبب غير معروف')),
                ],
                onChanged: (value) {},
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.save),
                label: const Text('حفظ السجل'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FeedForms extends StatelessWidget {
  final String farmId;
  final String? flockId;

  const FeedForms({Key? key, required this.farmId, this.flockId}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'استهلاك'),
              Tab(text: 'استلام'),
            ],
          ),
          SizedBox(
            height: 400,
            child: TabBarView(
              children: [
                _buildConsumptionForm(),
                _buildReceptionForm(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConsumptionForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            decoration: const InputDecoration(labelText: 'القطيع', border: OutlineInputBorder()),
            items: [const DropdownMenuItem(value: 'flock1', child: Text('قطيع أ-1'))],
            onChanged: (value) {},
          ),
          const SizedBox(height: 16),
          TextFormField(
            decoration: const InputDecoration(labelText: 'عدد الأكياس', border: OutlineInputBorder()),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.save),
            label: const Text('تسجيل الاستهلاك'),
            style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
          ),
        ],
      ),
    );
  }

  Widget _buildReceptionForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            decoration: const InputDecoration(labelText: 'نوع العلف', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'starter', child: Text('علف بادئ')),
              DropdownMenuItem(value: 'grower', child: Text('علف نامي')),
              DropdownMenuItem(value: 'layer', child: Text('علف بياض')),
            ],
            onChanged: (value) {},
          ),
          const SizedBox(height: 16),
          TextFormField(
            decoration: const InputDecoration(labelText: 'الكمية (كغ)', border: OutlineInputBorder()),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 16),
          TextFormField(
            decoration: const InputDecoration(labelText: 'اسم المورد', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.add_box),
            label: const Text('إضافة استلام'),
            style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
          ),
        ],
      ),
    );
  }
}

class MedicationForm extends StatelessWidget {
  final String farmId;
  final String? flockId;

  const MedicationForm({Key? key, required this.farmId, this.flockId}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('تسجيل الأدوية', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'القطيع', border: OutlineInputBorder()),
                items: [const DropdownMenuItem(value: 'flock1', child: Text('قطيع أ-1'))],
                onChanged: (value) {},
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(labelText: 'نوع الدواء', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(labelText: 'الجرعة', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.save),
                label: const Text('حفظ السجل'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DispatchForm extends StatelessWidget {
  final String farmId;
  final String? flockId;

  const DispatchForm({Key? key, required this.farmId, this.flockId}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('تسجيل التخريج', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'الزبون', border: OutlineInputBorder()),
                items: [const DropdownMenuItem(value: 'customer1', child: Text('أحمد محمد'))],
                onChanged: (value) {},
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(labelText: 'عدد الكرتون', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(labelText: 'السعر للكرتون', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.save),
                label: const Text('حفظ التخريج'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// أيقونة مخصصة
const IconData Icons鸡蛋 = IconData(0xe900, fontFamily: 'MaterialIcons');
