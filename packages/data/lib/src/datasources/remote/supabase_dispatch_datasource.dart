import 'package:core/core.dart';
import 'supabase_api.dart';

/// ظ…طµط¯ط± ط¨ظٹط§ظ†ط§طھ ط§ظ„طھط®ط±ظٹط¬ ط¹ط¨ط± Supabase
class SupabaseDispatchDatasource {
  final SupabaseApi _api;

  SupabaseDispatchDatasource(this._api);

  Future<String> insert(DispatchModel record) async {
    final data = await _api
        .from('egg_dispatch')
        .insert(record.toJson())
        .select(['id'])
        .single();

    return data['id'] as String;
  }

  /// ط±ظپط¹ ظ…ط¬ظ…ظˆط¹ط© ط³ط¬ظ„ط§طھ
  Future<BatchUploadResult> insertBatch(List<DispatchModel> records) async {
    final successIds = <String>[];
    final failedIds = <String>[];
    for (final r in records) {
      try {
        final id = await insert(r);
        successIds.add(r.id ?? id);
      } catch (_) {
        failedIds.add(r.id ?? '');
      }
    }
    return BatchUploadResult(successIds: successIds, failedIds: failedIds);
  }

  /// ط¥ط¶ط§ظپط©/طھط­ط¯ظٹط« ط²ط¨ظˆظ† (UPSERT ط¨ظ†ظپط³ ط§ظ„ظ…ط¹ط±ظ‘ظپ ط§ظ„ظ…ط­ظ„ظٹ ط­طھظ‰ طھطھط·ط§ط¨ظ‚ ط§ظ„ظ…ط²ط§ظ…ظ†ط©)
  Future<void> insertCustomer(String id, CustomerModel customer) async {
    final payload = customer.toJson()..['id'] = id;
    await _api
        .from('customers')
        .upsert(payload, onConflict: 'id')
        .run();
  }

  /// طھط¹ط¯ظٹظ„ ط¨ظٹط§ظ†ط§طھ ط²ط¨ظˆظ† ظپظٹ ط§ظ„ط³ط­ط§ط¨ط©
  Future<void> updateCustomer(CustomerModel customer) async {
    final id = customer.id;
    if (id == null) return;
    await _api
        .from('customers')
        .update({
          'name': customer.name,
          'phone': customer.phone,
          'notes': customer.notes,
        })
        .eq('id', id)
        .run();
  }

  /// ط­ط°ظپ ط²ط¨ظˆظ† ظ…ظ† ط§ظ„ط³ط­ط§ط¨ط©
  Future<void> deleteCustomer(String id) async {
    await _api.from('customers').delete().eq('id', id).run();
  }

  /// ط¬ظ„ط¨ ط§ظ„ط²ط¨ط§ط¦ظ†
  Future<List<CustomerModel>> getCustomers(String farmId) async {
    final data = await _api
        .from('customers')
        .select()
        .eq('farm_id', farmId)
        .order('name')
        .get();

    return (data)
        .map((e) => CustomerModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}