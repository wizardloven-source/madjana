import 'package:core/core.dart';
import 'supabase_api.dart';

/// ظ…طµط¯ط± ط¨ظٹط§ظ†ط§طھ ط§ظ„ط£ط±طµط¯ط© ط§ظ„ط§ظپطھطھط§ط­ظٹط© ط¹ط¨ط± Supabase
class SupabaseOpeningBalanceDatasource {
  final SupabaseApi _api;

  SupabaseOpeningBalanceDatasource(this._api);

  Future<OpeningBalanceModel?> getForFlock(
      String farmId, String flockId) async {
    final rows = await _api
        .from('opening_balances')
        .select()
        .eq('farm_id', farmId)
        .eq('flock_id', flockId)
        .limit(1)
        .get();
    if (rows.isEmpty) return null;
    return OpeningBalanceModel.fromJson(
        Map<String, dynamic>.from(rows.first as Map));
  }

  Future<List<OpeningBalanceModel>> getForFarm(String farmId) async {
    final rows = await _api
        .from('opening_balances')
        .select()
        .eq('farm_id', farmId)
        .get();
    return (rows)
        .map((e) => OpeningBalanceModel.fromJson(
            Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> upsert(OpeningBalanceModel balance) async {
    await _api.from('opening_balances').upsert(balance.toJson()).run();
  }

  Future<void> delete(String farmId, String flockId) async {
    await _api
        .from('opening_balances')
        .delete()
        .eq('farm_id', farmId)
        .eq('flock_id', flockId)
        .run();
  }
}