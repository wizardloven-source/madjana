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
  Future<List<String>> insertConsumptionBatch(
    List<FeedConsumptionModel> records,
  ) async {
    final successIds = <String>[];
    for (final r in records) {
      try {
        await insertConsumption(r);
        successIds.add(r.id ?? '');
      } catch (_) {}
    }
    return successIds;
  }

  /// رفع مجموعة استلام
  Future<List<String>> insertReceivedBatch(List<FeedReceivedModel> records) async {
    final successIds = <String>[];
    for (final r in records) {
      try {
        await insertReceived(r);
        successIds.add(r.id ?? '');
      } catch (_) {}
    }
    return successIds;
  }
}