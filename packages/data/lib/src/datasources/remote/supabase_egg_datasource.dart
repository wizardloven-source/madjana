import 'package:core/core.dart';
import 'supabase_api.dart';

/// ظ…طµط¯ط± ط¨ظٹط§ظ†ط§طھ ط¥ظ†طھط§ط¬ ط§ظ„ط¨ظٹط¶ ط¹ط¨ط± Supabase
class SupabaseEggDatasource {
  final SupabaseApi _api;

  SupabaseEggDatasource(this._api);

  /// ط§ظ„ظˆطµظˆظ„ ظ„ظ„ط¹ظ…ظٹظ„ (ظ„ظ„ط§ط³طھط¹ظ„ط§ظ…ط§طھ ط§ظ„ط¹ط§ظ…ط©)
  SupabaseApi get api => _api;

  /// ط±ظپط¹ ط³ط¬ظ„ ظˆط§ط­ط¯
  Future<String> insert(EggProductionModel record) async {
    final data = await _api
        .from('egg_production')
        .insert(record.toJson())
        .select(['id'])
        .single();

    return data['id'] as String;
  }

  /// ط±ظپط¹ ظ…ط¬ظ…ظˆط¹ط© ط³ط¬ظ„ط§طھ (Batch) - ظ„ظ„ظ…ط²ط§ظ…ظ†ط©
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

  /// ط­ط°ظپ ط³ط¬ظ„ ظ…ظ† ط§ظ„ط³ط­ط§ط¨ط©
  Future<void> delete(String id) async {
    await _api.from('egg_production').delete().eq('id', id).run();
  }

  /// ط¬ظ„ط¨ ط³ط¬ظ„ط§طھ ظ…ظ† ط§ظ„ط³ط­ط§ط¨ط© (ظ„ظ„طھظ‚ط§ط±ظٹط±)
  Future<List<EggProductionModel>> getRecords({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    var query = _api.from('egg_production').select();

    if (farmId != null) {
      query = query.eq('farm_id', farmId);
    }
    if (fromDate != null) {
      query = query.gte('date', fromDate.toIso8601String().split('T').first);
    }
    if (toDate != null) {
      query = query.lte('date', toDate.toIso8601String().split('T').first);
    }

    final data = await query.order('date', ascending: false).get();

    return (data)
        .map((e) => EggProductionModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}