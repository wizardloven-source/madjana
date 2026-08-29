import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات الأرصدة الافتتاحية عبر Supabase
class SupabaseOpeningBalanceDatasource {
  final SupabaseClient _client;

  SupabaseOpeningBalanceDatasource(this._client);

  Future<OpeningBalanceModel?> getForFlock(
      String farmId, String flockId) async {
    final rows = await _client
        .from('opening_balances')
        .select()
        .eq('farm_id', farmId)
        .eq('flock_id', flockId)
        .limit(1);
    if ((rows as List).isEmpty) return null;
    return OpeningBalanceModel.fromJson(
        Map<String, dynamic>.from(rows.first as Map));
  }

  Future<List<OpeningBalanceModel>> getForFarm(String farmId) async {
    final rows = await _client
        .from('opening_balances')
        .select()
        .eq('farm_id', farmId);
    return (rows as List)
        .map((e) => OpeningBalanceModel.fromJson(
            Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> upsert(OpeningBalanceModel balance) async {
    await _client.from('opening_balances').upsert(balance.toJson());
  }

  Future<void> delete(String farmId, String flockId) async {
    await _client
        .from('opening_balances')
        .delete()
        .eq('farm_id', farmId)
        .eq('flock_id', flockId);
  }
}