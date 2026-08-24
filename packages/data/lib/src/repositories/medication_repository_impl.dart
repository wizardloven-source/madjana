import 'package:core/core.dart';
import 'package:domain/domain.dart';
import '../datasources/local/daos/medication_dao.dart';
import '../datasources/remote/supabase_medication_datasource.dart';

/// تنفيذ مستودع الأدوية
class MedicationRepositoryImpl implements MedicationRepository {
  final MedicationDao _localDao;
  final SupabaseMedicationDatasource _remoteDatasource;

  MedicationRepositoryImpl({
    required MedicationDao localDao,
    required SupabaseMedicationDatasource remoteDatasource,
  })  : _localDao = localDao,
        _remoteDatasource = remoteDatasource;

  @override
  Future<void> saveLocal(MedicationModel record) async {
    await _localDao.insert(record);
  }

  @override
  Future<List<MedicineModel>> getMedicinesCatalog() async {
    final local = await _localDao.getCatalog();
    if (local.isNotEmpty) return local;

    // جلب من السحابة عند توفرها
    try {
      final remote = await _remoteDatasource.getMedicinesCatalog();
      if (remote.isNotEmpty) {
        await _localDao.seedCatalog(remote);
        return remote;
      }
    } catch (_) {
      // نستخدم القائمة الافتراضية
      return _defaultCatalog();
    }

    return _defaultCatalog();
  }

  @override
  Future<List<MedicationModel>> getAll({
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

  @override
  Future<void> syncPendingRecords() async {
    final pending = await _localDao.getPendingRecords();
    if (pending.isEmpty) return;

    final successIds = await _remoteDatasource.insertBatch(pending);
    for (final record in pending) {
      if (record.id == null) continue;
      await _localDao.updateSyncStatus(
        record.id!,
        successIds.contains(record.id)
            ? SyncStatus.synced
            : SyncStatus.failed,
      );
    }
  }

  @override
  Future<int> getPendingCount() => _localDao.countPending();

  /// قائمة أدوية افتراضية عند عدم وجود اتصال
  List<MedicineModel> _defaultCatalog() {
    return const [
      MedicineModel(
        id: 'med-1',
        name: 'فيتامين A+D3+E',
        type: MedicationType.vitamin,
        withdrawalDays: 0,
      ),
      MedicineModel(
        id: 'med-2',
        name: 'مضاد حيوي واسع الطيف',
        type: MedicationType.drug,
        withdrawalDays: 7,
      ),
      MedicineModel(
        id: 'med-3',
        name: 'لقاح نيوكاسل',
        type: MedicationType.vaccine,
        withdrawalDays: 21,
      ),
      MedicineModel(
        id: 'med-4',
        name: 'مطهر معوي',
        type: MedicationType.drug,
        withdrawalDays: 3,
      ),
      MedicineModel(
        id: 'med-5',
        name: 'فيتامين ك',
        type: MedicationType.vitamin,
        withdrawalDays: 0,
      ),
    ];
  }
}