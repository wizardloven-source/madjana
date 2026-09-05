import 'package:core/core.dart';
import 'supabase_api.dart';

/// ظ…طµط¯ط± ط¨ظٹط§ظ†ط§طھ ط§ظ„ظ…ط¯ظپظˆط¹ط§طھ ط¹ط¨ط± Supabase
class SupabasePaymentDatasource {
  final SupabaseApi _api;

  SupabasePaymentDatasource(this._api);

  Future<List<PaymentModel>> getPayments({
    required String farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    var query = _api.from('payments').select().eq('farm_id', farmId);
    if (fromDate != null) {
      query = query.gte(
          'date', fromDate.toIso8601String().split('T').first);
    }
    if (toDate != null) {
      query = query.lte('date', toDate.toIso8601String().split('T').first);
    }
    final data = await query.order('date').get();
    return (data)
        .map((e) => PaymentModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<Map<String, dynamic>> insert(PaymentModel payment) async {
    return _api
        .from('payments')
        .insert(payment.toJson())
        .select()
        .single();
  }

  Future<void> update(String id, PaymentModel payment) async {
    final json = payment.toJson()..remove('id');
    await _api.from('payments').update(json).eq('id', id).run();
  }

  Future<void> delete(String id) async {
    await _api.from('payments').delete().eq('id', id).run();
  }

  /// ط±ظپط¹ ظ…ط¬ظ…ظˆط¹ط© ط³ط¬ظ„ط§طھ
  Future<BatchUploadResult> insertBatch(List<PaymentModel> records) async {
    final successIds = <String>[];
    final failedIds = <String>[];
    for (final r in records) {
      try {
        final result = await insert(r);
        successIds.add(r.id ?? result['id'] as String);
      } catch (_) {
        failedIds.add(r.id ?? '');
      }
    }
    return BatchUploadResult(successIds: successIds, failedIds: failedIds);
  }
}