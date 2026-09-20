import '../constants/enums.dart';

/// نموذج القطيع
class FlockModel {
  final String id;
  final String farmId;
  final String breed;
  final DateTime startDate;
  final int initialCount;
  final int currentCount;
  final FlockStatus status;

  /// عدد العنابر في المدجنة (1..3)
  final int sectionsCount;
  final int version;
  final int? previousVersion;

  const FlockModel({
    required this.id,
    required this.farmId,
    required this.breed,
    required this.startDate,
    required this.initialCount,
    required this.currentCount,
    this.status = FlockStatus.active,
    this.sectionsCount = 1,
    this.version = 1,
    this.previousVersion,
  });

  /// ملاحظة: تم حذف الخاصية productionRate القديمة من هنا لأن صيغتها
  /// كانت خاطئة منطقياً (1 / currentCount * 100) — لا تعتمد على عدد
  /// البيض الفعلي المُنتَج إطلاقاً، بل تتناقص كلما زاد عدد الطيور بغض
  /// النظر عن الأداء الحقيقي. الحساب الصحيح لنسبة الإنتاج يتطلب عدد
  /// البيض المُنتَج فعلياً، وهو متوفر عبر:
  ///   FarmAnalytics.productionRate(eggs: ..., birdCount: ...)
  /// أو لمعدل فترة كاملة:
  ///   FarmAnalytics.avgProductionRate(totalEggs: ..., birdCount: ..., days: ...)
  /// استخدم هاتين الدالتين بدلاً من أي خاصية على FlockModel.

  /// العدد "الفعلي" المعروض: يصلح الحالات التي يكون فيها
  /// currentCount المخزن أقدم/فاسداً (أكبر من السقف المنطقي).
  ///
  /// السقف = العدد الأولي − النفوق الكلي (الافتتاحي + اليومي) مع تجاهل
  /// الصفر. نأخذ الأصغر بين المخزَّن والسقف كي لا نعرض رقماً يتجاوز
  /// الواقع، مع الإبقاء على الخصومات الشرعية (كبيع الطيور الحية).
  int effectiveCurrentCount({
    required int openingMortality,
    required int dailyMortality,
  }) {
    return effectiveCount(openingMortality + dailyMortality);
  }

  /// العدد "الفعلي" المعروض: لا يتجاوز (العدد الأولي − النفوق الكلي)،
  /// نأخذ الأصغر بين المخزَّن والسقف المنطقي.
  int effectiveCount(int totalMortality) {
    final derived = initialCount - totalMortality;
    final bound = derived < 0 ? 0 : derived;
    return currentCount < bound ? currentCount : bound;
  }

  /// نسخة من القطيع بعدد حالٍّ معدَّل — تُستخدم لتمرير العدد الفعلي
  /// إلى ميزات غير متزامنة داخل الواجهة.
  FlockModel copyWith({int? currentCount}) {
    return FlockModel(
      id: id,
      farmId: farmId,
      breed: breed,
      startDate: startDate,
      initialCount: initialCount,
      currentCount: currentCount ?? this.currentCount,
      status: status,
      sectionsCount: sectionsCount,
      version: version,
      previousVersion: previousVersion,
    );
  }

  /// عمر القطيع بالأيام من تاريخ البدء
  int get ageInDays => DateTime.now().difference(startDate).inDays;

  /// عمر القطيع بشكل مقروء (أيام/أسابيع/أشهر)
  String get ageLabel {
    final days = ageInDays;
    if (days < 7) return '$days يوم';
    if (days < 30) return '${days ~/ 7} أسابيع';
    if (days < 365) return '${days ~/ 30} أشهر';
    return '${days ~/ 365} سنوات و${(days % 365) ~/ 30} أشهر';
  }

  factory FlockModel.fromJson(Map<String, dynamic> json) {
    return FlockModel(
      id: json['id'] as String,
      farmId: json['farm_id'] as String,
      breed: json['breed'] as String,
      startDate: DateTime.parse(json['start_date'] as String),
      initialCount: json['initial_count'] as int,
      currentCount: json['current_count'] as int,
      status: FlockStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => FlockStatus.active,
      ),
      sectionsCount: json['sections_count'] as int? ?? 1,
      version: json['version'] as int? ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'farm_id': farmId,
        'breed': breed,
        'start_date': startDate.toIso8601String().split('T').first,
        'initial_count': initialCount,
        'current_count': currentCount,
        'status': status.name,
        'sections_count': sectionsCount,
        'version': version,
      };

  /// اسم مختصر للعرض
  String get displayName => '$breed (${currentCount} طائر)';
}