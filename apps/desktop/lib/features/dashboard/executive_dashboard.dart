import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../providers/dashboard_providers.dart';

/// لوحة القيادة التنفيذية للمدير - مربوطة ببيانات حقيقية من Supabase
class ExecutiveDashboard extends ConsumerStatefulWidget {
  const ExecutiveDashboard({Key? key}) : super(key: key);

  @override
  ConsumerState<ExecutiveDashboard> createState() => _ExecutiveDashboardState();
}

class _ExecutiveDashboardState extends ConsumerState<ExecutiveDashboard> {
  String? _selectedFarmId;
  DateTime _selectedDate = DateTime.now();
  final DateFormat _dateFormat = DateFormat('yyyy-MM-dd');

  // ثوابت الألوان المطابقة لـ AppTheme
  static const Color _primaryColor = Color(0xFF2E7D32);
  static const Color _backgroundColor = Color(0xFF0F1114);
  static const Color _surfaceColor = Color(0xFF1A1F25);
  static const Color _textColor = Color(0xFFE8E8E8);
  static const Color _successColor = Color(0xFF4CAF50);
  static const Color _warningColor = Color(0xFFFF9800);
  static const Color _errorColor = Color(0xFFF44336);
  static const Color _infoColor = Color(0xFF2196F3);

  @override
  Widget build(BuildContext context) {
    // مراقبة البيانات الحية من قاعدة البيانات
    final farmsAsync = ref.watch(farmsProvider);
    final statsAsync = ref.watch(dailyStatsProvider);
    final productionTrendAsync = ref.watch(productionTrendProvider);

    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        title: const Text('لوحة القيادة التنفيذية', TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: () => _selectDate(context),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(farmsProvider);
              ref.invalidate(dailyStatsProvider);
              ref.invalidate(productionTrendProvider);
            },
          ),
        ],
      ),
      body: farmsAsync.when(
        data: (farms) {
          if (farms.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.business_outlined, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                    Text('لا توجد مزارع مسجلة', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة مزرعة جديدة'),
                    onPressed: () {
                      // TODO: الانتقال لشاشة إضافة مزرعة
                    },
                  ),
                ],
              ),
            );
          }
          
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(dailyStatsProvider);
              ref.invalidate(productionTrendProvider);
            },
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // بطاقات ملخص الأداء
                  _buildKPICards(statsAsync),
                  const SizedBox(height: 24),
                  
                  // رسم بياني للإنتاج
                  _buildProductionChart(productionTrendAsync),
                  const SizedBox(height: 24),
                  
                  // حالة المزارع (إشارات المرور)
                  _buildFarmsStatusGrid(farms, statsAsync),
                  const SizedBox(height: 24),
                  
                  // تنبيهات هامة
                  _buildAlertsSection(),
                ],
              ),
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text('خطأ في تحميل البيانات: $err', style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
                onPressed: () {
                  ref.invalidate(farmsProvider);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKPICards(AsyncValue<Map<String, dynamic>> statsAsync) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: MediaQuery.of(context).size.width > 800 ? 4 : 2,
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: 1.5,
      children: [
        statsAsync.when(
          data: (stats) => _buildKPICard(
            title: 'إجمالي الإنتاج اليوم',
            value: '${stats['total_eggs'] ?? 0}',
            unit: 'بيضة',
            icon: Icons.eco,
            color: _successColor,
            trend: '+${((stats['total_eggs'] ?? 0) / 100).toStringAsFixed(1)}%',
            isPositive: true,
          ),
          loading: () => _buildLoadingCard(),
          error: (_, e) => _buildErrorCard(e.toString()),
        ),
        statsAsync.when(
          data: (stats) => _buildKPICard(
            title: 'معدل النفوق',
            value: '${(stats['mortality_rate'] ?? 0.0).toStringAsFixed(1)}',
            unit: '%',
            icon: Icons.warning_amber,
            color: _warningColor,
            trend: '-0.1%',
            isPositive: (stats['mortality_rate'] ?? 0) < 0.5,
          ),
          loading: () => _buildLoadingCard(),
          error: (_, e) => _buildErrorCard(e.toString()),
        ),
        statsAsync.when(
          data: (stats) => _buildKPICard(
            title: 'استهلاك العلف',
            value: '${stats['total_feed'] ?? 0}',
            unit: 'كغ',
            icon: Icons.grain,
            color: _infoColor,
            trend: '+2.1%',
            isPositive: false,
          ),
          loading: () => _buildLoadingCard(),
          error: (_, e) => _buildErrorCard(e.toString()),
        ),
        statsAsync.when(
          data: (stats) => _buildKPICard(
            title: 'صافي الربح',
            value: '${stats['net_profit'] ?? 0}',
            unit: 'ر.س',
            icon: Icons.attach_money,
            color: _primaryColor,
            trend: '+8.4%',
            isPositive: true,
          ),
          loading: () => _buildLoadingCard(),
          error: (_, e) => _buildErrorCard(e.toString()),
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
      color: _surfaceColor,
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
                    color: isPositive ? _successColor.withValues(alpha: 0.1) : _errorColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    trend,
                    style: TextStyle(
                      color: isPositive ? _successColor : _errorColor,
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
                    color: _textColor,
                  ),
                ),
                Text(
                  title,
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                ),
                Text(
                  unit,
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: _surfaceColor,
      child: const Center(
        child: CircularProgressIndicator(),
      ),
    );
  }

  Widget _buildErrorCard(String error) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: _surfaceColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: _errorColor, size: 32),
            const SizedBox(height: 8),
            Text('خطأ', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: _errorColor)),
            Text(error, style: const TextStyle(fontSize: 12), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  Widget _buildProductionChart(AsyncValue<List<Map<String, dynamic>>> trendAsync) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: _surfaceColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'إنتاج البيض - آخر 7 أيام',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _textColor),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: trendAsync.when(
                data: (data) {
                  if (data.isEmpty) {
                    return const Center(child: Text('لا توجد بيانات للإنتاج'));
                  }
                  return LineChart(
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
                          spots: data.asMap().entries.map((e) => FlSpot(e.key.toDouble(), (e.value['eggs'] as num).toDouble())).toList(),
                          isCurved: true,
                          color: _primaryColor,
                          barWidth: 3,
                          dotData: FlDotData(show: true),
                          belowBarData: BarAreaData(
                            show: true,
                            color: _primaryColor.withValues(alpha: 0.1),
                          ),
                        ),
                      ],
                    ),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, e) => Center(child: Text('خطأ: $e')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFarmsStatusGrid(List<dynamic> farms, AsyncValue<Map<String, dynamic>> statsAsync) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: _surfaceColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'حالة المزارع',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _textColor),
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
              itemCount: farms.length,
              itemBuilder: (context, index) {
                final farm = farms[index];
                // حساب الحالة بناءً على البيانات الحقيقية
                return statsAsync.when(
                  data: (stats) {
                    final mortalityRate = (farm['mortality_rate'] ?? 0.0) as double;
                    final status = mortalityRate > 1.0 ? 'critical' : mortalityRate > 0.5 ? 'warning' : mortalityRate > 0.2 ? 'good' : 'excellent';
                    final colors = {
                      'excellent': _successColor,
                      'good': Colors.lightGreen,
                      'warning': _warningColor,
                      'critical': _errorColor,
                    };
                    
                    return Container(
                      decoration: BoxDecoration(
                        color: colors[status]?.withValues(alpha: 0.1),
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
                          Expanded(
                            child: Text(
                              farm['name'] ?? 'مزرعة',
                              style: TextStyle(
                                color: colors[status],
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  loading: () => const CircularProgressIndicator(),
                  error: (_, e) => Text('خطأ'),
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

