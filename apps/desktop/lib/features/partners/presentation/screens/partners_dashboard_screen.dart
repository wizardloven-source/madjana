import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../data/partner_providers.dart';

/// لوحة تحكم الشركاء الرئيسية
class PartnersDashboardScreen extends ConsumerStatefulWidget {
  const PartnersDashboardScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<PartnersDashboardScreen> createState() => _PartnersDashboardScreenState();
}

class _PartnersDashboardScreenState extends ConsumerState<PartnersDashboardScreen> {
  @override
  Widget build(BuildContext context) {
    final partnersAsync = ref.watch(allPartnersProvider);
    final alertsAsync = ref.watch(contractAlertsProvider);

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('إدارة الشركاء'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showAddPartnerDialog(context),
            tooltip: 'إضافة شريك جديد',
          ),
          IconButton(
            icon: const Icon(Icons.file_download),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('ميزة التصدير قيد التطوير')),
              );
            },
            tooltip: 'تصدير إلى Excel',
          ),
        ],
      ),
      body: partnersAsync.when(
        data: (partners) {
          final activePartners = partners.where((p) => p.status == PartnerStatus.active).length;
          final totalProfits = partners.fold<double>(
            0,
            (sum, p) => sum + p.totalReceivedProfits,
          );

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStatsCards(activePartners, partners.length, totalProfits),
                const SizedBox(height: 32),
                alertsAsync.when(
                  data: (alerts) {
                    if (alerts.isEmpty) return const SizedBox.shrink();
                    return _buildContractAlerts(alerts);
                  },
                  loading: () => const CircularProgressIndicator(),
                  error: (_, __) => const SizedBox.shrink(),
                ),
                const SizedBox(height: 32),
                _buildPartnersTable(partners),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text('حدث خطأ: $error'),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
                onPressed: () => ref.invalidate(allPartnersProvider),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatsCards(int activeCount, int totalCount, double totalProfits) {
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: 1.5,
      children: [
        _StatCard(
          title: 'الشركاء النشطين',
          value: '$activeCount',
          icon: Icons.people,
          color: Colors.blue,
        ),
        _StatCard(
          title: 'إجمالي الشركاء',
          value: '$totalCount',
          icon: Icons.group,
          color: Colors.green,
        ),
        _StatCard(
          title: 'الأرباح الموزعة',
          value: '\$${totalProfits.toStringAsFixed(0)}',
          icon: Icons.attach_money,
          color: Colors.orange,
        ),
        _StatCard(
          title: 'تنبيهات العقود',
          value: '${ref.watch(contractAlertsProvider).value?.length ?? 0}',
          icon: Icons.warning_amber,
          color: Colors.red,
        ),
      ],
    );
  }

  Widget _buildContractAlerts(List<PartnerContractAlert> alerts) {
    return Card(
      color: Colors.amber[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning, color: Colors.amber[800]),
                const SizedBox(width: 8),
                Text(
                  'تنبيهات انتهاء العقود',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.amber[900],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...alerts.map((alert) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'تبقى ${alert.daysRemaining} يوماً على انتهاء عقد الشريك ${alert.partnerName}'
                      '${alert.farmName != null ? ' في ${alert.farmName}' : ''}',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildPartnersTable(List<PartnerModel> partners) {
    return Card(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('الاسم')),
            DataColumn(label: Text('رقم الجوال')),
            DataColumn(label: Text('المزارع')),
            DataColumn(label: Text('إجمالي الأرباح')),
            DataColumn(label: Text('آخر صرف')),
            DataColumn(label: Text('الحالة')),
            DataColumn(label: Text('إجراءات')),
          ],
          rows: partners.map((partner) {
            return DataRow(
              cells: [
                DataCell(Text(partner.name)),
                DataCell(Text(partner.phoneNumber)),
                DataCell(const Text('- مزرعة')),
                DataCell(Text('\$${partner.totalReceivedProfits.toStringAsFixed(0)}')),
                DataCell(Text(partner.updatedAt.toString().split(' ')[0])),
                DataCell(Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: partner.status == PartnerStatus.active
                        ? Colors.green[100]
                        : partner.status == PartnerStatus.suspended
                            ? Colors.orange[100]
                            : Colors.red[100],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    partner.status.arabicName,
                    style: TextStyle(
                      color: partner.status == PartnerStatus.active
                          ? Colors.green[900]
                          : partner.status == PartnerStatus.suspended
                              ? Colors.orange[900]
                              : Colors.red[900],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )),
                DataCell(Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.visibility, size: 20),
                      onPressed: () => _navigateToPartnerDetails(partner.id),
                      tooltip: 'عرض',
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit, size: 20),
                      onPressed: () => _showEditPartnerDialog(context, partner),
                      tooltip: 'تعديل',
                    ),
                  ],
                )),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showAddPartnerDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إضافة شريك جديد'),
        content: const Text('نموذج إضافة شريك جديد - قيد التطوير'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  void _showEditPartnerDialog(BuildContext context, PartnerModel partner) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('تعديل بيانات الشريك: ${partner.name}'),
        content: const Text('نموذج تعديل الشريك - قيد التطوير'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('حفظ التعديلات'),
          ),
        ],
      ),
    );
  }

  void _navigateToPartnerDetails(String partnerId) {
    // TODO: الانتقال لصفحة التفاصيل
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    Key? key,
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, color: color, size: 32),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
