import 'dart:io';
import 'package:core/core.dart';
import 'package:domain/domain.dart';
import '../datasources/local/daos/mortality_dao.dart';
import '../datasources/remote/supabase_mortality_datasource.dart';

/// تنفيذ مستودع النفوق
class MortalityRepositoryImpl implements MortalityRepository {
  final MortalityDao _localDao;
  final SupabaseMortalityDatasource _remoteDatasource;

  MortalityRepositoryImpl({
    required MortalityDao localDao,
    required SupabaseMortalityDatasource remoteDatasource,
  })  : _localDao = localDao,
        _remoteDatasource = remoteDatasource;

  @override
  Future<void> saveLocal(MortalityModel record) async {
    await _localDao.insert(record);
  }

  @override
  Future<int> getFlockCurrentCount(String flockId) {
    return _localDao.getFlockCurrentCount(flockId);
  }

  @override
  Future<List<MortalityModel>> getTodayRecords(String farmId) {
    return _localDao.getTodayRecords(farmId);
  }

  @override
  Future<List<MortalityModel>> getAllRecords({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) {
    return _localDao.getAll(
      farmId: farmId,
      fromDate: fromDate,
      toDate: toDate,
    );
  }

  /// رفع صورة إلى السحابة
  Future<String?> uploadImage(File imageFile, String recordId,
      {required String farmId}) async {
    try {
      return await _remoteDatasource.uploadImage(imageFile, recordId, farmId);
    } catch (e) {
      // في حالة فشل الرفع، نكمل بدون صورة (Offline-first)
      return null;
    }
  }

  /// مزامنة السجلات المعلقة
  Future<void> syncPendingRecords() async {
    final pending = await _localDao.getPendingRecords();
    if (pending.isEmpty) return;

    final successIds = await _remoteDatasource.insertBatch(pending);

    for (final record in pending) {
      if (record.id == null) continue;
      if (successIds.successIds.contains(record.id)) {
        await _localDao.updateSyncStatus(record.id!, SyncStatus.synced);
      } else {
        await _localDao.updateSyncStatus(record.id!, SyncStatus.failed);
      }
    }
  }

  @override
  Future<void> deleteRecord(String id) async {
    await _localDao.delete(id);
    try {
      await _remoteDatasource.delete(id);
    } catch (_) {
      // سيتم مزامنتها لاحقاً
    }
  }
}