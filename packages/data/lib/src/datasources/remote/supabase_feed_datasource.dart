import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات العلف عبر Supabase
class SupabaseFeedDatasource {
  final SupabaseClient _client;

  SupabaseFeedDatasource(this._client);

  Future<void> insertConsumption(FeedConsumptionModel record) async {
    await _client.from('feed_consumption').insert(record.toJson());
  }

  Future<void> insertReceived(FeedReceivedModel record) async {
    await _client.from('feed_received').insert(record.toJson());
  }

  /// تحديث سعر الكيلوغرام (تسعير المدير من سطح المكتب)
  Future<void> updateReceivedPrice(String id, double pricePerKg) async {
    await _client
        .from('feed_received')
        .update({'price_per_kg': pricePerKg}).eq('id', id);
  }

  /// رفع مجموعة استهلاك
  Future<BatchUploadResult> insertConsumptionBatch(
    List<FeedConsumptionModel> records,
  ) async {
    final successIds = <String>[];
    final failedIds = <String>[];
    for (final r in records) {
      try {
        await insertConsumption(r);
        successIds.add(r.id ?? '');
      } catch (_) {
        failedIds.add(r.id ?? '');
      }
    }
    return BatchUploadResult(successIds: successIds, failedIds: failedIds);
  }

  /// رفع مجموعة استلام
  Future<BatchUploadResult> insertReceivedBatch(List<FeedReceivedModel> records) async {
    final successIds = <String>[];
    final failedIds = <String>[];
    for (final r in records) {
      try {
        await insertReceived(r);
        successIds.add(r.id ?? '');
      } catch (_) {
        failedIds.add(r.id ?? '');
      }
    }
    return BatchUploadResult(successIds: successIds, failedIds: failedIds);
  }

  /// حذف سجل استهلاك من السحابة
  Future<void> deleteConsumption(String id) async {
    await _client.from('feed_consumption').delete().eq('id', id);
  }
}
