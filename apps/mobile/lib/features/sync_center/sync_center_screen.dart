import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// مركز المزامنة للعامل
/// يعرض حالة المزامنة وسجل العمليات وإمكانية المزامنة اليدوية
class SyncCenterScreen extends ConsumerStatefulWidget {
  const SyncCenterScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<SyncCenterScreen> createState() => _SyncCenterScreenState();
}

class _SyncCenterScreenState extends ConsumerState<SyncCenterScreen> {
  bool _isSyncing = false;
  int _pendingCount = 0;
  int _syncedCount = 0;
  int _failedCount = 0;
  DateTime? _lastSyncTime;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مركز المزامنة'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isSyncing ? null : _performSync,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => _performSync(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // بطاقة الحالة العامة
              _buildStatusCard(),
              const SizedBox(height: 24),

              // إحصائيات مفصلة
              _buildStatsGrid(),
              const SizedBox(height: 24),

              // سجل المزامنة
              _buildSyncLog(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final statusColor = _failedCount > 0 ? Colors.orange : (_pendingCount > 0 ? Colors.blue : Colors.green);
    final statusText = _failedCount > 0 
        ? 'توجد أخطاء' 
        : (_pendingCount > 0 ? 'قيد الانتظار' : 'محدث');

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [statusColor.withOpacity(0.1), statusColor.withOpacity(0.3)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 120,
                  height: 120,
                  child: CircularProgressIndicator(
                    value: _isSyncing ? null : 1.0,
                    strokeWidth: 8,
                    backgroundColor: Colors.grey[200],
                    color: statusColor,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isSyncing ? Icons.sync : Icons.cloud_done,
                      size: 48,
                      color: statusColor,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isSyncing ? 'جاري...' : '${_pendingCount}',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              statusText,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: statusColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _lastSyncTime != null
                  ? 'آخر مزامنة: ${_formatDateTime(_lastSyncTime!)}'
                  : 'لم تتم مزامنة بعد',
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isSyncing ? null : _performSync,
              icon: Icon(_isSyncing ? Icons.sync : Icons.cloud_upload),
              label: Text(_isSyncing ? 'جاري المزامنة...' : 'مزامنة الآن'),
              style: ElevatedButton.styleFrom(
                backgroundColor: statusColor,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsGrid() {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 3,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1,
      children: [
        _buildStatItem('قيد الانتظار', _pendingCount, Colors.blue, Icons.pending),
        _buildStatItem('تم المزامنة', _syncedCount, Colors.green, Icons.check_circle),
        _buildStatItem('فشل', _failedCount, Colors.red, Icons.error),
      ],
    );
  }

  Widget _buildStatItem(String label, int count, Color color, IconData icon) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 8),
            Text(
              count.toString(),
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncLog() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'سجل المزامنة',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: () {},
                  child: const Text('عرض الكل'),
                ),
              ],
            ),
            const Divider(),
            _buildLogItem('إنتاج البيض', 'تمت المزامنة بنجاح', Colors.green, DateTime.now()),
            _buildLogItem('النفوق', 'تمت المزامنة بنجاح', Colors.green, DateTime.now().subtract(const Duration(minutes: 5))),
            _buildLogItem('العلف', 'في انتظار المزامنة', Colors.orange, DateTime.now().subtract(const Duration(minutes: 10))),
            _buildLogItem('التخريج', 'فشل المزامنة - إعادة المحاولة', Colors.red, DateTime.now().subtract(const Duration(hours: 1))),
          ],
        ),
      ),
    );
  }

  Widget _buildLogItem(String table, String message, Color color, DateTime time) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withOpacity(0.1),
        child: Icon(
          color == Colors.green ? Icons.check : (color == Colors.red ? Icons.error : Icons.pending),
          color: color,
          size: 20,
        ),
      ),
      title: Text(table, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(message, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      trailing: Text(
        _formatRelativeTime(time),
        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
      ),
    );
  }

  Future<void> _performSync() async {
    setState(() => _isSyncing = true);
    
    // محاكاة عملية المزامنة
    await Future.delayed(const Duration(seconds: 3));
    
    if (!mounted) return;
    
    setState(() {
      _isSyncing = false;
      _lastSyncTime = DateTime.now();
      _pendingCount = 0;
      _syncedCount += 5;
    });

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ تمت المزامنة بنجاح'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} - ${dt.day}/${dt.month}';
  }

  String _formatRelativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inHours < 24) return 'منذ ${diff.inHours} ساعة';
    return 'منذ ${diff.inDays} يوم';
  }
}
