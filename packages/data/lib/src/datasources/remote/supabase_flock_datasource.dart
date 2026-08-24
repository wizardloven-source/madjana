import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات القطعان عبر Supabase
class SupabaseFlockDatasource {
  final SupabaseClient _client;

  SupabaseFlockDatasource(this._client);

  Future<List<FlockModel>> getFlocks(String farmId, {bool includeEnded = true}) {
    final query = _client.from('flocks').select().eq('farm_id', farmId);
    return query.then((data) {
      var flocks = (data as List)
          .map((e) => FlockModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!includeEnded) {
        flocks = flocks.where((f) => f.status == FlockStatus.active).toList();
      }
      return flocks;
    });
  }

  Future<void> insert(FlockModel flock) async {
    await _client.from('flocks').insert(flock.toJson());
  }

  Future<void> update(FlockModel flock) async {
    await _client.from('flocks').update(flock.toJson()).eq('id', flock.id);
  }

  Future<void> endFlock(String flockId) async {
    await _client
        .from('flocks')
        .update({'status': FlockStatus.depleted.name}).eq('id', flockId);
  }
}
