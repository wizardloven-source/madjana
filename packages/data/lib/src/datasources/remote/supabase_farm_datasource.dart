import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات المدجنة عبر Supabase
class SupabaseFarmDatasource {
  final SupabaseClient _client;

  SupabaseFarmDatasource(this._client);

  Future<FarmModel> getFarm(String farmId) async {
    final data =
        await _client.from('farms').select().eq('id', farmId).maybeSingle();
    if (data == null) throw StateError('المدجنة غير موجودة');
    return FarmModel.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<void> update(FarmModel farm) async {
    final json = farm.toJson()..remove('id');
    await _client.from('farms').update(json).eq('id', farm.id);
  }
}
