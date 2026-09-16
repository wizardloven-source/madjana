import 'package:core/core.dart';
import 'supabase_api.dart';

class SupabaseRevenueDatasource {
  final SupabaseApi _api;

  SupabaseRevenueDatasource(this._api);

  Future<List<RevenueModel>> getRevenues({
    required String farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    var query = _api.from('revenue').select().eq('farm_id', farmId);
    if (fromDate != null) {
      query = query.gte('date', fromDate.toIso8601String().split('T').first);
    }
    if (toDate != null) {
      query = query.lte('date', toDate.toIso8601String().split('T').first);
    }
    final data = await query.order('date').get();
    return data
        .map((e) => RevenueModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<Map<String, dynamic>> insert(RevenueModel revenue) async {
    return _api.from('revenue').insert(revenue.toJson()).select().single();
  }

  Future<void> update(String id, RevenueModel revenue) async {
    final json = revenue.toJson()..remove('id');
    await _api.from('revenue').update(json).eq('id', id).run();
  }

  Future<void> delete(String id) async {
    await _api.from('revenue').delete().eq('id', id).run();
  }
}
