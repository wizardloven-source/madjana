import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات إنتاج البيض عبر Supabase
class SupabaseEggDatasource {
  final SupabaseClient _client;

  SupabaseEggDatasource(this._client);

  /// الوصول للعميل (للاستعلامات العامة)
  SupabaseClient get client => _client;

  /// رفع سجل واحد
  Future<String> insert(EggProductionModel record) async {
    final data = await _client
        .from('egg_production')
        .insert(record.toJson())
        .select('id')
        .single();

    return data['id'] as String;
  }

  /// رفع مجموعة سجلات (Batch) - للمزامنة
  Future<BatchUploadResult> insertBatch(List<EggProductionModel> records) async {
    final successIds = <String>[];
    final failedIds = <String>[];

    for (final record in records) {
      try {
        final id = await insert(record);
        successIds.add(record.id ?? id);
      } catch (e) {
        failedIds.add(record.id ?? '');
      }
    }

    return BatchUploadResult(
      successIds: successIds,
      failedIds: failedIds,
    );
  }

  /// حذف سجل من السحابة
  Future<void> delete(String id) async {
    await _client.from('egg_production').delete().eq('id', id);
  }

  /// جلب سجلات من السحابة (للتقارير)
  Future<List<EggProductionModel>> getRecords({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    var query = _client.from('egg_production').select();

    if (farmId != null) {
      query = query.eq('farm_id', farmId);
    }
    if (fromDate != null) {
      query = query.gte('date', fromDate.toIso8601String().split('T').first);
    }
    if (toDate != null) {
      query = query.lte('date', toDate.toIso8601String().split('T').first);
    }

    final data = await query.order('date', ascending: false);

    return (data as List)
        .map((e) => EggProductionModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}