import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات الأدوية عبر Supabase
class SupabaseMedicationDatasource {
  final SupabaseClient _client;

  SupabaseMedicationDatasource(this._client);

  Future<void> insert(MedicationModel record) async {
    await _client.from('medications').insert(record.toJson());
  }

  /// رفع مجموعة سجلات
  Future<List<String>> insertBatch(List<MedicationModel> records) async {
    final successIds = <String>[];
    for (final r in records) {
      try {
        await insert(r);
        successIds.add(r.id ?? '');
      } catch (_) {}
    }
    return successIds;
  }

  /// جلب كتالوج الأدوية
  Future<List<MedicineModel>> getMedicinesCatalog() async {
    final data = await _client.from('medicines_catalog').select().order('name');

    return (data as List)
        .map((e) => MedicineModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}