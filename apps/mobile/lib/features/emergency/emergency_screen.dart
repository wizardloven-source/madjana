import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// شاشة طوارئ للعامل
/// تتيح إرسال تنبيه فوري للمدير عند وجود مشكلة حرجة
class EmergencyScreen extends ConsumerStatefulWidget {
  const EmergencyScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends ConsumerState<EmergencyScreen> {
  String? _selectedEmergencyType;
  String _description = '';
  bool _isSending = false;

  final List<Map<String, dynamic>> _emergencyTypes = [
    {'icon': Icons.local_fire_department, 'label': 'حريق', 'color': Colors.red},
    {'icon': Icons.biotech, 'label': 'وباء مرضي', 'color': Colors.orange},
    {'icon': Icons.electrical_services, 'label': 'انقطاع كهرباء', 'color': Colors.yellow},
    {'icon': Icons.water_drop, 'label': 'انقطاع مياه', 'color': Colors.blue},
    {'icon': Icons.thermostat, 'label': 'ارتفاع حرارة', 'color': Colors.deepOrange},
    {'icon': Icons.warning, 'label': 'أخرى', 'color': Colors.grey},
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.red[50],
      appBar: AppBar(
        title: const Text('🚨 حالة الطوارئ'),
        backgroundColor: Colors.red,
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
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red),
              ),
              child: Row(
                children: [
                  Icon(Icons.error, color: Colors.red, size: 40),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'تنبيه طارئ!',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red),
                        ),
                        Text(
                          'سيتم إرسال هذا التنبيه فوراً إلى المدير وجميع المشرفين',
                          style: TextStyle(color: Colors.red[700]),
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
                          color: isSelected ? Colors.white : type['color'],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          type['label'],
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: isSelected ? Colors.white : Colors.black,
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
            const SizedBox(height: 32),

            // زر الإرسال
            ElevatedButton(
              onPressed: _selectedEmergencyType == null || _isSending ? null : _sendEmergency,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
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
    setState(() => _isSending = true);
    
    // محاكاة إرسال التنبيه
    await Future.delayed(const Duration(seconds: 2));
    
    if (!mounted) return;
    
    setState(() => _isSending = false);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.check_circle, color: Colors.green, size: 60),
        title: const Text('تم الإرسال!'),
        content: Text('تم إرسال تنبيه الطوارئ بنجاح إلى المدير بخصوص: $_selectedEmergencyType'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('موافق'),
          ),
        ],
      ),
    );
  }
}
