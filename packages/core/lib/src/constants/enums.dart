/// أدوار المستخدمين
enum UserRole {
  worker,
  manager,
  system_admin;

  String get label {
    switch (this) {
      case UserRole.worker:
        return 'عامل';
      case UserRole.manager:
        return 'مدير';
      case UserRole.system_admin:
        return 'مدير النظام';
    }
  }

  /// هل يمكنه رؤية البيانات المالية؟
  bool get canViewFinancials =>
      this == UserRole.manager || this == UserRole.system_admin;

  /// هل يمكنه التعديل/الحذف؟
  bool get canEdit =>
      this == UserRole.manager || this == UserRole.system_admin;

  /// هل هو مدير النظام (يرى كل المداجن)?
  bool get isAdmin => this == UserRole.system_admin;
}

/// حالة القطيع
enum FlockStatus { active, depleted }

/// حالة الدفع
enum PaymentStatus { unpaid, partial, paid }

/// طريقة الدفع
enum PaymentMethod { cash, transfer, check, credit }

/// نوع العلف
enum FeedType { main, starter, grower, layer }

/// طريقة إدخال العلف
enum FeedEntryMode { bags, kg, ton }

/// نوع الإجراء الدوائي
enum MedicationType { drug, vaccine, vitamin }

/// طريقة إعطاء الدواء
enum AdministrationRoute { water, spray, injection, feed }

/// أسباب النفوق
enum MortalityReason {
  notEating('لم يأكل / لم يشرب'),
  internalBleeding('نزيف داخلي'),
  immunityBreak('كسر مناعة'),
  heatStress('اختناق / إجهاد حراري'),
  cannibalism('افتراس'),
  unknown('سبب مجهول'),
  other('أخرى');

  final String label;
  const MortalityReason(this.label);

  /// قيمة السبب كما تُخزَّن في قاعدة البيانات (snake_case)
  String get dbValue {
    switch (this) {
      case MortalityReason.notEating:
        return 'not_eating';
      case MortalityReason.internalBleeding:
        return 'internal_bleeding';
      case MortalityReason.immunityBreak:
        return 'immunity_break';
      case MortalityReason.heatStress:
        return 'heat_stress';
      case MortalityReason.cannibalism:
        return 'cannibalism';
      case MortalityReason.unknown:
        return 'unknown';
      case MortalityReason.other:
        return 'other';
    }
  }

  /// تحويل قيمة قاعدة البيانات إلى السبب (يقبل أيضاً القيم camelCase القديمة)/
  static MortalityReason fromDbValue(String value) {
    for (final e in MortalityReason.values) {
      if (e.dbValue == value || e.name == value) return e;
    }
    return MortalityReason.other;
  }
}

/// حالة المزامنة
enum SyncStatus { pending, synced, failed, processing, conflict }

/// فئات الإيرادات
enum RevenueCategory {
  liveChicken('بيع دجاج حي'),
  eggSales('مبيعات البيض'),
  building('بيع عمارة/مساحة'),
  equipment('بيع عدة/تجهيزات'),
  other('أشياء أخرى');

  final String label;
  const RevenueCategory(this.label);
}

/// فئات المصروفات
enum ExpenseCategory {
  electricity('كهرباء'),
  water('ماء'),
  labor('عمالة'),
  maintenance('صيانة'),
  transport('نقل وتوصيل'),
  feed('علف'),
  medicine('أدوية وتطعيمات'),
  carton('صحون كرتون'),
  other('أخرى');

  final String label;
  const ExpenseCategory(this.label);
}

/// عملة الإدخال (الدولار هو الأساسي للعرض والتخزين)
enum AppCurrency {
  dollar('دولار', '\$'),
  lira('ليرة', 'ل.س');

  final String label;
  final String symbol;
  const AppCurrency(this.label, this.symbol);

  static AppCurrency fromName(String? name) {
    return AppCurrency.values.firstWhere(
      (e) => e.name == name,
      orElse: () => AppCurrency.dollar,
    );
  }
}

/// وحدات قياس المخزون
enum InventoryUnit {
  piece('وحدة'),
  kg('كيلوغرام'),
  liter('لتر'),
  bag('كيس'),
  vial('فيال'),
  box('علبة');

  final String label;
  const InventoryUnit(this.label);
}

// ═══════════════════════════════════════════════
// W6 — الشركاء (partners)
// ═══════════════════════════════════════════════

/// حالة الشريك — `partners.status`
enum PartnerStatus {
  active('نشط'),
  inactive('غير نشط'),
  suspended('موقوف');

  final String label;
  const PartnerStatus(this.label);

  static PartnerStatus fromName(String? name) => PartnerStatus.values.firstWhere(
        (e) => e.name == name,
        orElse: () => PartnerStatus.active,
      );
}

/// طبيعة الشريك — `partners.partner_role`.
///
/// وصفية فقط ولا تمنح أي صلاحية؛ كون الشخص شريكاً لا يمنحه وصولاً مالياً.
enum PartnerRole {
  investor('مستثمر'),
  worker('عامل'),
  manager('مدير'),
  silent('شريك صامت'),
  mixed('مختلط');

  final String label;
  const PartnerRole(this.label);

  static PartnerRole fromName(String? name) =>
      PartnerRole.values.firstWhere(
        (e) => e.name == name,
        orElse: () => PartnerRole.investor,
      );
}

/// نموذج الحصة — `partners.share_model`
enum ShareModel {
  percentage('نسبة مئوية'),
  shares('أسهم'),
  salary('راتب'),
  mixed('مختلط');

  final String label;
  const ShareModel(this.label);

  static ShareModel fromName(String? name) => ShareModel.values
      .firstWhere((e) => e.name == name, orElse: () => ShareModel.percentage);
}

/// دورة الراتب — `partners.salary_period`
enum SalaryPeriod {
  monthly('شهري', 'monthly'),
  weekly('أسبوعي', 'weekly'),
  daily('يومي', 'daily'),
  perCycle('لكل دورة', 'per_cycle');

  final String label;
  final String dbValue;
  const SalaryPeriod(this.label, this.dbValue);

  static SalaryPeriod? fromDb(String? value) {
    if (value == null) return null;
    for (final e in SalaryPeriod.values) {
      if (e.dbValue == value) return e;
    }
    return null;
  }
}