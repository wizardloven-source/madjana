import 'package:core/core.dart';
import 'supabase_api.dart';

/// ظ…طµط¯ط± ط¨ظٹط§ظ†ط§طھ ط§ظ„ط¹ظ„ظپ ط¹ط¨ط± Supabase
class SupabaseFeedDatasource {
  final SupabaseApi _api;

  SupabaseFeedDatasource(this._api);

  Future<void> insertConsumption(FeedConsumptionModel record) async {
    await _api.from('feed_consumption').insert(record.toJson()).run();
  }

  Future<void> insertReceived(FeedReceivedModel record) async {
    await _api.from('feed_received').insert(record.toJson()).run();
  }

  /// طھط­ط¯ظٹط« ط³ط¹ط± ط§ظ„ظƒظٹظ„ظˆط؛ط±ط§ظ… (طھط³ط¹ظٹط± ط§ظ„ظ…ط¯ظٹط± ظ…ظ† ط³ط·ط­ ط§ظ„ظ…ظƒطھط¨)
  Future<void> updateReceivedPrice(String id, double pricePerKg) async {
    await _api
        .from('feed_received')
        .update({'price_per_kg': pricePerKg}).eq('id', id)
        .run();
  }

  /// ط±ظپط¹ ظ…ط¬ظ…ظˆط¹ط© ط§ط³طھظ‡ظ„ط§ظƒ
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

  /// ط±ظپط¹ ظ…ط¬ظ…ظˆط¹ط© ط§ط³طھظ„ط§ظ…
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

  /// ط­ط°ظپ ط³ط¬ظ„ ط§ط³طھظ‡ظ„ط§ظƒ ظ…ظ† ط§ظ„ط³ط­ط§ط¨ط©
  Future<void> deleteConsumption(String id) async {
    await _api.from('feed_consumption').delete().eq('id', id).run();
  }
}