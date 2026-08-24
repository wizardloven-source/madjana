import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات المصروفات عبر Supabase
class SupabaseExpenseDatasource {
  final SupabaseClient _client;

  SupabaseExpenseDatasource(this._client);

  Future<List<ExpenseModel>> getExpenses({
    required String farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    var query = _client.from('expenses').select().eq('farm_id', farmId);
    if (fromDate != null) {
      query = query.gte(
          'date', fromDate.toIso8601String().split('T').first);
    }
    if (toDate != null) {
      query = query.lte('date', toDate.toIso8601String().split('T').first);
    }
    final data = await query.order('date');
    return (data as List)
        .map((e) => ExpenseModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<Map<String, dynamic>> insert(ExpenseModel expense) async {
    return Map<String, dynamic>.from(
      await _client.from('expenses').insert(expense.toJson()).select().single(),
    );
  }

  Future<void> update(String id, ExpenseModel expense) async {
    final json = expense.toJson()..remove('id');
    await _client.from('expenses').update(json).eq('id', id);
  }

  Future<void> delete(String id) async {
    await _client.from('expenses').delete().eq('id', id);
  }
}
