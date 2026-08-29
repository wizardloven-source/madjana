import 'dart:io';
import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات النفوق عبر Supabase
class SupabaseMortalityDatasource {
  final SupabaseClient _client;

  SupabaseMortalityDatasource(this._client);

  /// رفع سجل
  Future<String> insert(MortalityModel record) async {
    final data = await _client
        .from('mortality')
        .insert(record.toJson())
        .select('id')
        .single();

    return data['id'] as String;
  }

  /// رفع صورة النفوق إلى Storage
  Future<String> uploadImage(File imageFile, String recordId) async {
    final fileName = '${DateTime.now().millisecondsSinceEpoch}_$recordId.jpg';
    final path = 'mortality/$fileName';

    await _client.storage.from('farm-images').upload(
          path,
          imageFile,
          fileOptions: const FileOptions(cacheControl: '3600', upsert: false),
        );

    // الحصول على الرابط العام
    final url = await _client.storage.from('farm-images').getPublicUrl(path);
    return url;
  }

  /// رفع مجموعة سجلات
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

  /// حذف سجل من السحابة
  Future<void> delete(String id) async {
    await _client.from('mortality').delete().eq('id', id);
  }
}
