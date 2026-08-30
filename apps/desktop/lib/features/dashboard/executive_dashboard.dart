import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

/// لوحة القيادة التنفيذية للمدير
/// تعرض مؤشرات الأداء الرئيسية لجميع المزارع
class ExecutiveDashboard extends ConsumerStatefulWidget {
  const ExecutiveDashboard({Key? key}) : super(key: key);

  @override
  ConsumerState<ExecutiveDashboard> createState() => _ExecutiveDashboardState();
}

class _ExecutiveDashboardState extends ConsumerState<ExecutiveDashboard> {
  String? _selectedFarmId;
  DateTime _selectedDate = DateTime.now();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('لوحة القيادة التنفيذية'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: () => _selectDate(context),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => setState(() {}),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // بطاقات ملخص الأداء
              _buildKPICards(),
              const SizedBox(height: 24),
              
              // رسم بياني للإنتاج
              _buildProductionChart(),
              const SizedBox(height: 24),
              
              // حالة المزارع (إشارات المرور)
              _buildFarmsStatusGrid(),
              const SizedBox(height: 24),
              
              // تنبيهات هامة
              _buildAlertsSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKPICards() {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: MediaQuery.of(context).size.width > 800 ? 4 : 2,
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: 1.5,
      children: [
        _buildKPICard(
          title: 'إجمالي الإنتاج اليوم',
          value: '12,450',
          unit: 'بيضة',
          icon: Icons鸡蛋,
          color: Colors.green,
          trend: '+5.2%',
          isPositive: true,
        ),
        _buildKPICard(
          title: 'معدل النفوق',
          value: '0.3',
          unit: '%',
          icon: Icons.warning_amber,
          color: Colors.orange,
          trend: '-0.1%',
          isPositive: true,
        ),
        _buildKPICard(
          title: 'استهلاك العلف',
          value: '2,340',
          unit: 'كغ',
          icon: Icons.grain,
          color: Colors.blue,
          trend: '+2.1%',
          isPositive: false,
        ),
        _buildKPICard(
          title: 'صافي الربح',
          value: '4,520',
          unit: 'ر.س',
          icon: Icons.attach_money,
          color: Colors.purple,
          trend: '+8.4%',
          isPositive: true,
        ),
      ],
    );
  }

  Widget _buildKPICard({
    required String title,
    required String value,
    required String unit,
    required IconData icon,
    required Color color,
    required String trend,
    required bool isPositive,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, color: color, size: 28),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isPositive ? Colors.green[50] : Colors.red[50],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    trend,
                    style: TextStyle(
                      color: isPositive ? Colors.green[700] : Colors.red[700],
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
                Text(
                  unit,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey[500],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProductionChart() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'إنتاج البيض - آخر 7 أيام',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true, drawVerticalLine: false),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          const days = ['السبت', 'الأحد', 'الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة'];
                          return Text(
                            days[value.toInt() % 7],
                            style: const TextStyle(fontSize: 10),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: [
                        const FlSpot(0, 12000),
                        const FlSpot(1, 12500),
                        const FlSpot(2, 11800),
                        const FlSpot(3, 13000),
                        const FlSpot(4, 12800),
                        const FlSpot(5, 13500),
                        const FlSpot(6, 14000),
                      ],
                      isCurved: true,
                      color: Colors.green,
                      barWidth: 3,
                      dotData: FlDotData(show: true),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.green.withOpacity(0.1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFarmsStatusGrid() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'حالة المزارع',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 2,
              ),
              itemCount: 5, // عدد المزارع
              itemBuilder: (context, index) {
                final statuses = ['excellent', 'good', 'warning', 'critical', 'excellent'];
                final colors = {
                  'excellent': Colors.green,
                  'good': Colors.lightGreen,
                  'warning': Colors.orange,
                  'critical': Colors.red,
                };
                final status = statuses[index];
                
                return Container(
                  decoration: BoxDecoration(
                    color: colors[status]?.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colors[status]!),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: colors[status],
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'مزرعة ${index + 1}',
                        style: TextStyle(
                          color: colors[status],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertsSection() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'تنبيهات هامة',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _buildAlertItem(
              'نقص في مخزون العلف - مزرعة 2',
              'يتبقى 2 طن فقط، يرجى الطلب',
              Colors.orange,
              Icons.warning,
            ),
            _buildAlertItem(
              'ارتفاع معدل النفوق - مزرعة 1',
              'تجاوز الحد المسموح به بنسبة 0.5%',
              Colors.red,
              Icons.error,
            ),
            _buildAlertItem(
              'صيانة دورية مطلوبة',
              'موعد صيانة المعدات خلال 3 أيام',
              Colors.blue,
              Icons.build,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertItem(String title, String subtitle, Color color, IconData icon) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(subtitle, style: TextStyle(color: Colors.grey[600])),
      trailing: Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey[400]),
      onTap: () {},
    );
  }

  Future<void> _selectDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }
}

// أيقونة مخصصة للبيض
const IconData Icons鸡蛋 = IconData(0xe900, fontFamily: 'MaterialIcons');
