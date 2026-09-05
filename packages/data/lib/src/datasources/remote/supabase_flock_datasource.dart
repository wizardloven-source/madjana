import 'package:core/core.dart';
import 'supabase_api.dart';

/// ظ…طµط¯ط± ط¨ظٹط§ظ†ط§طھ ط§ظ„ظ‚ط·ط¹ط§ظ† ط¹ط¨ط± Supabase
class SupabaseFlockDatasource {
  final SupabaseApi _api;

  SupabaseFlockDatasource(this._api);

  Future<List<FlockModel>> getFlocks(String farmId, {bool includeEnded = true}) {
    final query = _api.from('flocks').select().eq('farm_id', farmId);
    return query.get().then((data) {
      var flocks = (data)
          .map((e) => FlockModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!includeEnded) {
        flocks = flocks.where((f) => f.status == FlockStatus.active).toList();
      }
      return flocks;
    });
  }

  Future<void> insert(FlockModel flock) async {
    await _api.from('flocks').insert(flock.toJson()).run();
  }

  Future<void> update(FlockModel flock) async {
    await _api.from('flocks').update(flock.toJson()).eq('id', flock.id).run();
  }

  Future<void> endFlock(String flockId) async {
    await _api
        .from('flocks')
        .update({'status': FlockStatus.depleted.name}).eq('id', flockId)
        .run();
  }
}