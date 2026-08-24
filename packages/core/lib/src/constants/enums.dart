/// أدوار المستخدمين
enum UserRole {
  worker,
  supervisor,
  manager;

  String get label {
    switch (this) {
      case UserRole.worker:
        return 'عامل';
      case UserRole.supervisor:
        return 'مشرف';
      case UserRole.manager:
        return 'مدير';
    }
  }

  /// هل يمكنه رؤية البيانات المالية؟
  bool get canViewFinancials => this == UserRole.manager;

  /// هل يمكنه التعديل/الحذف؟
  bool get canEdit => this == UserRole.manager;
}

/// حالة القطيع
enum FlockStatus { active, depleted }

/// حالة الدفع
enum PaymentStatus { unpaid, partial, paid }

/// طريقة الدفع
enum PaymentMethod { cash, transfer, check, credit }

/// نوع العلف
enum FeedType { starter, grower, layer }

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
enum SyncStatus { pending, synced, failed, processing }

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