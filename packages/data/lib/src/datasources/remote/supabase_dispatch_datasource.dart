import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات التخريج عبر Supabase
class SupabaseDispatchDatasource {
  final SupabaseClient _client;

  SupabaseDispatchDatasource(this._client);

  Future<String> insert(DispatchModel record) async {
    final data = await _client
        .from('egg_dispatch')
        .insert(record.toJson())
        .select('id')
        .single();

    return data['id'] as String;
  }

  /// رفع مجموعة سجلات
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

  /// إضافة/تحديث زبون (UPSERT بنفس المعرّف المحلي حتى تتطابق المزامنة)
  Future<void> insertCustomer(String id, CustomerModel customer) async {
    final payload = customer.toJson()..['id'] = id;
    await _client
        .from('customers')
        .upsert(payload, onConflict: 'id');
  }

  /// تعديل بيانات زبون في السحابة
  Future<void> updateCustomer(CustomerModel customer) async {
    final id = customer.id;
    if (id == null) return;
    await _client
        .from('customers')
        .update({
          'name': customer.name,
          'phone': customer.phone,
          'notes': customer.notes,
        })
        .eq('id', id);
  }

  /// حذف زبون من السحابة
  Future<void> deleteCustomer(String id) async {
    await _client.from('customers').delete().eq('id', id);
  }

  /// جلب الزبائن
  Future<List<CustomerModel>> getCustomers(String farmId) async {
    final data = await _client
        .from('customers')
        .select()
        .eq('farm_id', farmId)
        .order('name');

    return (data as List)
        .map((e) => CustomerModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}
