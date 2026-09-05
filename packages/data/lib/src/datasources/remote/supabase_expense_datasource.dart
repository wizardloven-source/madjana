import 'package:core/core.dart';
import 'supabase_api.dart';

/// ظ…طµط¯ط± ط¨ظٹط§ظ†ط§طھ ط§ظ„ظ…طµط±ظˆظپط§طھ ط¹ط¨ط± Supabase
class SupabaseExpenseDatasource {
  final SupabaseApi _api;

  SupabaseExpenseDatasource(this._api);

  Future<List<ExpenseModel>> getExpenses({
    required String farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    var query = _api.from('expenses').select().eq('farm_id', farmId);
    if (fromDate != null) {
      query = query.gte(
          'date', fromDate.toIso8601String().split('T').first);
    }
    if (toDate != null) {
      query = query.lte('date', toDate.toIso8601String().split('T').first);
    }
    final data = await query.order('date').get();
    return (data)
        .map((e) => ExpenseModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<Map<String, dynamic>> insert(ExpenseModel expense) async {
    return _api.from('expenses').insert(expense.toJson()).select().single();
  }

  Future<void> update(String id, ExpenseModel expense) async {
    final json = expense.toJson()..remove('id');
    await _api.from('expenses').update(json).eq('id', id).run();
  }

  Future<void> delete(String id) async {
    await _api.from('expenses').delete().eq('id', id).run();
  }
}