import 'package:core/core.dart';
import 'supabase_api.dart';

/// ظ…طµط¯ط± ط¨ظٹط§ظ†ط§طھ ط§ظ„ط£ط¯ظˆظٹط© ط¹ط¨ط± Supabase
class SupabaseMedicationDatasource {
  final SupabaseApi _api;

  SupabaseMedicationDatasource(this._api);

  Future<void> insert(MedicationModel record) async {
    await _api.from('medications').insert(record.toJson()).run();
  }

  /// ط±ظپط¹ ظ…ط¬ظ…ظˆط¹ط© ط³ط¬ظ„ط§طھ
  Future<BatchUploadResult> insertBatch(List<MedicationModel> records) async {
    final successIds = <String>[];
    final failedIds = <String>[];
    for (final r in records) {
      try {
        await insert(r);
        successIds.add(r.id ?? '');
      } catch (_) {
        failedIds.add(r.id ?? '');
      }
    }
    return BatchUploadResult(successIds: successIds, failedIds: failedIds);
  }

  /// ط¬ظ„ط¨ ظƒطھط§ظ„ظˆط¬ ط§ظ„ط£ط¯ظˆظٹط©
  Future<List<MedicineModel>> getMedicinesCatalog() async {
    final data = await _api.from('medicines_catalog').select().order('name').get();

    return (data)
        .map((e) => MedicineModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}