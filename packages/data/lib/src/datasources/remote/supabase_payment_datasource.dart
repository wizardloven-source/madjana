import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات المدفوعات عبر Supabase
class SupabasePaymentDatasource {
  final SupabaseClient _client;

  SupabasePaymentDatasource(this._client);

  Future<List<PaymentModel>> getPayments({
    required String farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    var query = _client.from('payments').select().eq('farm_id', farmId);
    if (fromDate != null) {
      query = query.gte(
          'date', fromDate.toIso8601String().split('T').first);
    }
    if (toDate != null) {
      query = query.lte('date', toDate.toIso8601String().split('T').first);
    }
    final data = await query.order('date');
    return (data as List)
        .map((e) => PaymentModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<Map<String, dynamic>> insert(PaymentModel payment) async {
    return Map<String, dynamic>.from(
      await _client.from('payments').insert(payment.toJson()).select().single(),
    );
  }

  Future<void> update(String id, PaymentModel payment) async {
    final json = payment.toJson()..remove('id');
    await _client.from('payments').update(json).eq('id', id);
  }

  Future<void> delete(String id) async {
    await _client.from('payments').delete().eq('id', id);
  }

  /// رفع مجموعة سجلات
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
