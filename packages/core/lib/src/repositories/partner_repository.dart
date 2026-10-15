import '../models/partner_model.dart';

/// إدارة الشركاء (W6) — سطح المكتب.
///
/// الكتابة على `partners` محصورة بـ`is_system_admin()` في RLS. أما المدير
/// فيرى الشركاء الذين لهم أعمال في مدجنته عبر `partner_in_manager_farm(id)`
/// (M25)، لذا قد ترفض القاعدة إنشاء شريك جديد من حساب مدير، والرسالة تتصاعد
/// كما هي بدل إخفائها.
abstract class PartnerRepository {
  /// الشركاء غير المحذوفين (deleted_at IS NULL).
  Future<List<PartnerModel>> getPartners();

  /// كل الشركاء بما فيهم المحذوفون (لعرضهم/استعادتهم).
  Future<List<PartnerModel>> getPartnersIncludingDeleted();

  /// إنشاء (بلا id) أو تعديل (بـid) شريك.
  Future<void> save(PartnerModel partner);

  /// حذف منطقي: يضبط deleted_at.
  Future<void> softDelete(String id);

  /// استعادة شريك محذوف (deleted_at = null).
  Future<void> restore(String id);
}
