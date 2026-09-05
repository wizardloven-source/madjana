import 'dart:io';
import 'package:core/core.dart';
import 'supabase_api.dart';

/// ظ…طµط¯ط± ط¨ظٹط§ظ†ط§طھ ط§ظ„ظ†ظپظˆظ‚ ط¹ط¨ط± Supabase
class SupabaseMortalityDatasource {
  final SupabaseApi _api;

  SupabaseMortalityDatasource(this._api);

  /// ط±ظپط¹ ط³ط¬ظ„
  Future<String> insert(MortalityModel record) async {
    final data = await _api
        .from('mortality')
        .insert(record.toJson())
        .select(['id'])
        .single();

    return data['id'] as String;
  }

  /// ط±ظپط¹ طµظˆط±ط© ط§ظ„ظ†ظپظˆظ‚ ط¥ظ„ظ‰ Storage
  /// P0/28: ظ…ط³ط§ط± ظ…ط¹ط²ظˆظ„ ط¨ط§ظ„ظ…ط²ط±ط¹ط© â€” farms/{farm_id}/mortality/{record_id}/...
  Future<String> uploadImage(File imageFile, String recordId, String farmId) async {
    final fileName = '${DateTime.now().millisecondsSinceEpoch}_$recordId.jpg';
    final path = 'farms/$farmId/mortality/$recordId/$fileName';

    await _api.storage.upload(
      'farm-images',
      path,
      imageFile,
      cacheControl: '3600',
      upsert: false,
      contentType: 'image/jpeg',
    );

    // ط§ظ„ط­طµظˆظ„ ط¹ظ„ظ‰ ط§ظ„ط±ط§ط¨ط· ط§ظ„ط¹ط§ظ…
    final url = _api.storage.getPublicUrl('farm-images', path);
    return url;
  }

  /// ط±ظپط¹ ظ…ط¬ظ…ظˆط¹ط© ط³ط¬ظ„ط§طھ
  Future<BatchUploadResult> insertBatch(List<MortalityModel> records) async {
    final successIds = <String>[];
    final failedIds = <String>[];
    for (final record in records) {
      try {
        final id = await insert(record);
        successIds.add(record.id ?? id);
      } catch (_) {
        failedIds.add(record.id ?? '');
      }
    }
    return BatchUploadResult(successIds: successIds, failedIds: failedIds);
  }

  /// ط­ط°ظپ ط³ط¬ظ„ ظ…ظ† ط§ظ„ط³ط­ط§ط¨ط©
  Future<void> delete(String id) async {
    await _api.from('mortality').delete().eq('id', id).run();
  }
}