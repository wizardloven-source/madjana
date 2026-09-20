import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/design_tokens.dart';
import '../../sync/providers/sync_provider.dart';
import 'providers/emergency_provider.dart';

/// شاشة طوارئ للعامل
/// تتيح إرسال تنبيه فوري للمدير عند وجود مشكلة حرجة
/// Offline-first: عند الانقطاع يُحفظ التنبيه محلياً ويُرسل عند عودة الاتصال
class EmergencyScreen extends ConsumerStatefulWidget {
  const EmergencyScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends ConsumerState<EmergencyScreen> {
  String? _selectedEmergencyType;
  String _description = '';
  bool _isSending = false;

  ProviderSubscription<SyncConnectionStatus>? _statusSub;

  final List<Map<String, dynamic>> _emergencyTypes = [
    {'icon': Icons.local_fire_department, 'label': 'حريق', 'color': AppColors.danger, 'fg': Colors.white},
    {'icon': Icons.biotech, 'label': 'وباء مرضي', 'color': AppColors.warning, 'fg': Colors.white},
    {'icon': Icons.electrical_services, 'label': 'انقطاع كهرباء', 'color': AppColors.warning, 'fg': Colors.black87},
    {'icon': Icons.water_drop, 'label': 'انقطاع مياه', 'color': AppColors.info, 'fg': Colors.white},
    {'icon': Icons.thermostat, 'label': 'ارتفاع حرارة', 'color': AppColors.danger, 'fg': Colors.white},
    {'icon': Icons.warning, 'label': 'أخرى', 'color': AppColors.textTertiary, 'fg': Colors.white},
  ];

  @override
  void initState() {
    super.initState();
    // محاولة تسليم أي تنبيهات معلقة من جلسة سابقة عند فتح الشاشة
    WidgetsBinding.instance.addPostFrameCallback((_) => _retryPending());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // عند عودة الاتصال: إرسال التنبيهات المحلية المعلقة تلقائياً
    _statusSub ??= ref.listenManual<SyncConnectionStatus>(
      syncProvider.select((s) => s.connectionStatus),
      (prev, next) {
        if (next == SyncConnectionStatus.connected &&
            prev != SyncConnectionStatus.connected) {
          _retryPending();
        }
      },
    );
  }

  @override
  void dispose() {
    _statusSub?.close();
    super.dispose();
  }

  Future<void> _retryPending() async {
    if (!mounted) return;
    await ref.read(emergencyProvider.notifier).retryPending();
  }

  @override
  Widget build(BuildContext context) {
    final pendingCount = ref.watch(emergencyProvider.select((s) => s.pendingCount));
    return Scaffold(
      backgroundColor: AppColors.danger.withOpacity(0.05),
      appBar: AppBar(
        title: const Text('🚨 حالة الطوارئ'),
        backgroundColor: AppColors.danger,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // تحذير
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.danger.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.danger),
              ),
              child: Row(
                children: [
                  Icon(Icons.error, color: AppColors.danger, size: 40),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'تنبيه طارئ!',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.danger),
                        ),
                        Text(
                          'سيتم إرسال هذا التنبيه فوراً إلى المدير وجميع المشرفين',
                          style: TextStyle(color: AppColors.danger),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // أنواع الطوارئ
            const Text(
              'نوع الحالة الطارئة:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.5,
              ),
              itemCount: _emergencyTypes.length,
              itemBuilder: (context, index) {
                final type = _emergencyTypes[index];
                final isSelected = _selectedEmergencyType == type['label'];
                
                return GestureDetector(
                  onTap: () => setState(() => _selectedEmergencyType = type['label']),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected ? type['color'] : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected ? type['color'] : Colors.grey[300]!,
                        width: 2,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          type['icon'],
                          size: 40,
                          color: isSelected ? type['fg'] : type['color'],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          type['label'],
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: isSelected ? type['fg'] : Colors.black,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 24),

            // وصف إضافي
            const Text(
              'وصف إضافي (اختياري):',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextFormField(
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'اكتب أي تفاصيل إضافية...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.white,
              ),
              onChanged: (value) => setState(() => _description = value),
            ),
            const SizedBox(height: 16),

            // تنبيه المعلّقة محلياً (غير متصل)
            if (pendingCount > 0) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.warning),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_off, color: AppColors.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'لديك $pendingCount تنبيه لم يُرسل بعد — سيُرسل تلقائياً عند عودة الاتصال',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // زر الإرسال
            ElevatedButton(
              onPressed: _selectedEmergencyType == null || _isSending ? null : _sendEmergency,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.danger,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 56),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _isSending
                  ? const SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : const Text(
                      '🚨 إرسال تنبيه الطوارئ',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendEmergency() async {
    final type = _selectedEmergencyType;
    if (type == null) return;

    setState(() => _isSending = true);

    final result = await ref
        .read(emergencyProvider.notifier)
        .submit(alertType: type, description: _description);

    if (!mounted) return;
    setState(() => _isSending = false);

    if (result.sent) {
      _showDialog(
        icon: Icons.check_circle,
        color: AppColors.success,
        title: 'تم الإرسال!',
        content: 'تم إرسال تنبيه الطوارئ بنجاح إلى المدير بخصوص: $type',
        onOk: () {
          Navigator.pop(context);
          Navigator.pop(context);
        },
      );
    } else if (result.queued) {
      _showDialog(
        icon: Icons.cloud_off,
        color: AppColors.warning,
        title: 'حُفظ محلياً',
        content: 'أنت غير متصل بالإنترنت — سيُرسل التنبيه تلقائياً إلى المدير '
            'فور عودة الاتصال.',
        onOk: () {
          Navigator.pop(context);
          Navigator.pop(context);
        },
      );
    } else {
      _showDialog(
        icon: Icons.error,
        color: AppColors.danger,
        title: 'فشل الإرسال',
        content: result.error ?? 'تعذّر إرسال التنبيه.',
        onOk: () => Navigator.pop(context),
      );
    }
  }

  void _showDialog({
    required IconData icon,
    required Color color,
    required String title,
    required String content,
    required VoidCallback onOk,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(icon, color: color, size: 60),
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: onOk,
            child: const Text('موافق'),
          ),
        ],
      ),
    );
  }
}
