import 'package:core/core.dart';
import 'supabase_api.dart';

/// مصدر بيانات الشركاء عبر Supabase (W6).
///
/// صفحة `partners` صغيرة، والحذف منطقي (`deleted_at`)، فالترشيح يجري محلياً
/// بعد الجلب — الواجهة المجرّدة [SupabaseApi] لا تعرض مرشّح `is null`.
class SupabasePartnerDatasource {
  final SupabaseApi _api;

  SupabasePartnerDatasource(this._api);

  /// جلب الشركاء مرتّبين بالاسم؛ ومن غير المحذوفين افتراضياً.
  Future<List<PartnerModel>> fetch({bool includeDeleted = false}) async {
    final rows = await _api.from('partners').select().order('name').get();
    final partners = rows
        .map((e) => PartnerModel.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    if (includeDeleted) return partners;
    return partners.where((p) => !p.isDeleted).toList();
  }

  Future<void> insert(PartnerModel partner) async {
    final json = Map<String, dynamic>.from(partner.toJson())..remove('id');
    await _api.from('partners').insert(json).run();
  }

  Future<void> update(PartnerModel partner) async {
    final json = Map<String, dynamic>.from(partner.toJson())..remove('id');
    await _api.from('partners').update(json).eq('id', partner.id!).run();
  }

  Future<void> softDelete(String id) async {
    await _api.from('partners').update({
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', id).run();
  }

  Future<void> restore(String id) async {
    await _api.from('partners').update({'deleted_at': null}).eq('id', id).run();
  }
}
