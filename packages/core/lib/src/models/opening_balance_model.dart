/// بيانات عنبر واحد داخل قطيع قديم
class OpeningSectionModel {
  final int sectionNo;
  final int initialBirds;
  final int mortalityCount;

  const OpeningSectionModel({
    required this.sectionNo,
    required this.initialBirds,
    this.mortalityCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'section_no': sectionNo,
        'initial_birds': initialBirds,
        'mortality_count': mortalityCount,
      };

  factory OpeningSectionModel.fromJson(Map<String, dynamic> json) {
    return OpeningSectionModel(
      sectionNo: json['section_no'] as int,
      initialBirds: json['initial_birds'] as int,
      mortalityCount: json['mortality_count'] as int? ?? 0,
    );
  }
}

/// الأرصدة الافتتاحية لقطيع قديم دخل الخدمة قبل النظام
///
/// تُحفظ مرة واحدة عند إعداد قطيع قديم، وتُضاف إلى مجاميع
/// لوحة التحكم والتقارير (إنتاج بيض، تخريج، علف، نفوق، مدفوعات، إيرادات).
class OpeningBalanceModel {
  final String id;
  final String farmId;
  final String flockId;

  /// تاريخ تجهيز الأرصدة
  final DateTime createdAt;

  /// إجمالي البيض المنتج حتى الآن
  final int eggsProduced;

  /// إجمالي البيض المُخرَّج حتى الآن
  final int eggsDispatched;

  /// إجمالي العلف المستهلك حتى الآن (كغ)
  final double feedConsumedKg;

  /// عدد الدجاج الأولي قبل تشغيل النظام
  final int initialBirds;

  /// إجمالي النفوق حتى الآن
  final int mortalityCount;

  /// إجمالي المدفوعات المصروفة حتى الآن
  final double totalPayments;

  /// إجمالي الإيرادات المحصّلة حتى الآن
  final double totalRevenues;

  /// تفصيل العنابر (كُل عنبر: العدد الأولي + النفوق)
  final List<OpeningSectionModel> sections;

  const OpeningBalanceModel({
    required this.id,
    required this.farmId,
    required this.flockId,
    required this.createdAt,
    this.eggsProduced = 0,
    this.eggsDispatched = 0,
    this.feedConsumedKg = 0,
    this.initialBirds = 0,
    this.mortalityCount = 0,
    this.totalPayments = 0,
    this.totalRevenues = 0,
    this.sections = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'farm_id': farmId,
        'flock_id': flockId,
        'created_at': createdAt.toIso8601String(),
        'eggs_produced': eggsProduced,
        'eggs_dispatched': eggsDispatched,
        'feed_consumed_kg': feedConsumedKg,
        'initial_birds': initialBirds,
        'mortality_count': mortalityCount,
        'total_payments': totalPayments,
        'total_revenues': totalRevenues,
        'sections': sections.map((s) => s.toJson()).toList(),
      };

  factory OpeningBalanceModel.fromJson(Map<String, dynamic> json) {
    return OpeningBalanceModel(
      id: json['id'] as String,
      farmId: json['farm_id'] as String,
      flockId: json['flock_id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      eggsProduced: json['eggs_produced'] as int? ?? 0,
      eggsDispatched: json['eggs_dispatched'] as int? ?? 0,
      feedConsumedKg: (json['feed_consumed_kg'] as num?)?.toDouble() ?? 0,
      initialBirds: json['initial_birds'] as int? ?? 0,
      mortalityCount: json['mortality_count'] as int? ?? 0,
      totalPayments: (json['total_payments'] as num?)?.toDouble() ?? 0,
      totalRevenues: (json['total_revenues'] as num?)?.toDouble() ?? 0,
      sections: (json['sections'] as List? ?? const [])
          .map((e) => OpeningSectionModel.fromJson(
              Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }

  /// إجمالي النفوق عبر العنابر (للتحقق من تطابقه مع الكلي)
  int get sectionsMortalityTotal =>
      sections.fold(0, (s, sec) => s + sec.mortalityCount);

  /// عدد الطيور الحالي المقدر = الأولي - النفوق الكلي
  int get currentBirds => initialBirds - mortalityCount;
}