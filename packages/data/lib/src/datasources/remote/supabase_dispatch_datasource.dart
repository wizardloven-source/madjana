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
  Future<List<String>> insertBatch(List<DispatchModel> records) async {
    final successIds = <String>[];
    for (final r in records) {
      try {
        final id = await insert(r);
        successIds.add(r.id ?? id);
      } catch (_) {}
    }
    return successIds;
  }

  /// إضافة زبون جديد
  Future<String> insertCustomer(CustomerModel customer) async {
    final data = await _client
        .from('customers')
        .insert(customer.toJson())
        .select('id')
        .single();

    return data['id'] as String;
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