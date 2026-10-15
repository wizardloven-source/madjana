import 'package:core/core.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../datasources/remote/supabase_partner_datasource.dart';

/// تنفيذ إدارة الشركاء (W6).
///
/// الشركاء غير مُزامَنين محلياً (لا DAO محلي)، فالمصدر هو السحابة مباشرة.
/// تُترجم أخطاء PostgREST إلى رسالة الاستثناء الحقيقية (مثلاً رفض RLS أو
/// خرق قيد share_model) بدل نصّ عام غامض.
class PartnerRepositoryImpl implements PartnerRepository {
  final SupabasePartnerDatasource _remoteDatasource;

  PartnerRepositoryImpl({required SupabasePartnerDatasource remoteDatasource})
      : _remoteDatasource = remoteDatasource;

  static String _realMessage(Object e) {
    try {
      final msg = (e as dynamic).message as String?;
      if (msg != null && msg.trim().isNotEmpty) return msg.trim();
    } catch (e) {
      debugPrint('madjana: partner message extract failed: $e');
    }
    return e.toString().replaceFirst('Exception: ', '');
  }

  @override
  Future<List<PartnerModel>> getPartners() async {
    try {
      return await _remoteDatasource.fetch();
    } catch (e) {
      throw Exception(_realMessage(e));
    }
  }

  @override
  Future<List<PartnerModel>> getPartnersIncludingDeleted() async {
    try {
      return await _remoteDatasource.fetch(includeDeleted: true);
    } catch (e) {
      throw Exception(_realMessage(e));
    }
  }

  @override
  Future<void> save(PartnerModel partner) async {
    try {
      if (partner.id == null) {
        await _remoteDatasource.insert(partner);
      } else {
        await _remoteDatasource.update(partner);
      }
    } catch (e) {
      throw Exception(_realMessage(e));
    }
  }

  @override
  Future<void> softDelete(String id) async {
    try {
      await _remoteDatasource.softDelete(id);
    } catch (e) {
      throw Exception(_realMessage(e));
    }
  }

  @override
  Future<void> restore(String id) async {
    try {
      await _remoteDatasource.restore(id);
    } catch (e) {
      throw Exception(_realMessage(e));
    }
  }
}
