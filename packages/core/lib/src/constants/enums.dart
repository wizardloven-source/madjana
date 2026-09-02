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
}

/// حالة المزامنة
enum SyncStatus { pending, synced, failed, processing, conflict }

/// فئات المصروفات
enum ExpenseCategory {
  electricity('كهرباء'),
  water('ماء'),
  labor('عمالة'),
  maintenance('صيانة'),
  transport('نقل وتوصيل'),
  feed('علف'),
  medicine('أدوية وتطعيمات'),
  other('أخرى');

  final String label;
  const ExpenseCategory(this.label);
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