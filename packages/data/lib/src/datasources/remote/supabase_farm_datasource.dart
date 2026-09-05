import 'package:core/core.dart';
import 'supabase_api.dart';

/// ظ…طµط¯ط± ط¨ظٹط§ظ†ط§طھ ط§ظ„ظ…ط¯ط¬ظ†ط© ط¹ط¨ط± Supabase
class SupabaseFarmDatasource {
  final SupabaseApi _api;

  SupabaseFarmDatasource(this._api);

  Future<FarmModel> getFarm(String farmId) async {
    final data = await _api.from('farms').select().eq('id', farmId).maybeSingle();
    if (data == null) throw StateError('ط§ظ„ظ…ط¯ط¬ظ†ط© ط؛ظٹط± ظ…ظˆط¬ظˆط¯ط©');
    return FarmModel.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<void> update(FarmModel farm) async {
    final json = farm.toJson()..remove('id');
    await _api.from('farms').update(json).eq('id', farm.id).run();
  }
}