import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database.dart';

/// DAO للأدوية (السجلات + الكتالوج)
class MedicationDao {
  static const String _table = 'medications';
  static const String _catalogTable = 'medicines_catalog';
  static const _uuid = Uuid();

  Future<String> insert(MedicationModel record) async {
    final db = await LocalDatabase.database;
    final id = _uuid.v4();

    await db.insert(_table, {
      'id': id,
      'farm_id': record.farmId,
      'date': record.date.toIso8601String().split('T').first,
      'type': record.type.name,
      'medicine_name': record.medicineName,
      'dosage': record.dosage,
      'administration_route': record.administrationRoute.name,
      'treatment_days': record.treatmentDays,
      'withdrawal_days': record.withdrawalDays,
      'notes': record.notes,
      'worker_id': record.workerId,
      'sync_status': SyncStatus.pending.name,
      'created_at': DateTime.now().toIso8601String(),
    });

    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: id,
      action: 'INSERT',
      payload: {
        'date': record.date.toIso8601String().split('T').first,
        'type': record.type.name,
        'medicine_name': record.medicineName,
        'dosage': record.dosage,
        'administration_route': record.administrationRoute.name,
        'treatment_days': record.treatmentDays,
        'withdrawal_days': record.withdrawalDays,
        'notes': record.notes,
        'worker_id': record.workerId,
      },
    );

    return id;
  }

  Future<List<MedicationModel>> getPendingRecords({int limit = 50}) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'sync_status = ?',
      whereArgs: [SyncStatus.pending.name],
      limit: limit,
    );
    return maps.map(_fromMap).toList();
  }

  Future<int> countPending() async {
    final db = await LocalDatabase.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_table WHERE sync_status = ?',
      [SyncStatus.pending.name],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> updateSyncStatus(String id, SyncStatus status) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {'sync_status': status.name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    final db = await LocalDatabase.database;
    final existing = await db.query(_table, columns: ['version'], where: 'id = ?', whereArgs: [id], limit: 1);
    final ver = existing.isNotEmpty ? (existing.first['version'] as int?) ?? 1 : 1;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: id,
      action: 'DELETE',
      previousVersion: ver,
      payload: {'id': id},
    );
  }

  Future<List<MedicationModel>> getAll({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final db = await LocalDatabase.database;
    final where = <String>[];
    final args = <dynamic>[];

    if (farmId != null) {
      where.add('farm_id = ?');
      args.add(farmId);
    }
    if (fromDate != null) {
      where.add('date >= ?');
      args.add(fromDate.toIso8601String().split('T').first);
    }
    if (toDate != null) {
      where.add('date <= ?');
      args.add(toDate.toIso8601String().split('T').first);
    }

    final maps = await db.query(
      _table,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'date DESC',
    );
    return maps.map(_fromMap).toList();
  }

  /// استبدال سجل دواء محلي بالنسخة السحابية (حل التعارض)
  Future<void> replaceWithRemote(MedicationModel model) async {
    final db = await LocalDatabase.database;
    await db.update(
      _table,
      {
        'farm_id': model.farmId,
        'date': model.date.toIso8601String().split('T').first,
        'type': model.type.name,
        'medicine_name': model.medicineName,
        'dosage': model.dosage,
        'administration_route': model.administrationRoute.name,
        'treatment_days': model.treatmentDays,
        'withdrawal_days': model.withdrawalDays,
        'notes': model.notes,
        'worker_id': model.workerId,
        'sync_status': SyncStatus.synced.name,
      },
      where: 'id = ?',
      whereArgs: [model.id],
    );
  }

  Future<void> insertOrUpdateCatalogItem(MedicineModel medicine) async {
    final db = await LocalDatabase.database;
    await db.insert(
      _catalogTable,
      {
        'id': medicine.id,
        'name': medicine.name,
        'type': medicine.type.name,
        'withdrawal_days': medicine.withdrawalDays,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteCatalogItem(String id) async {
    final db = await LocalDatabase.database;
    await db.delete(_catalogTable, where: 'id = ?', whereArgs: [id]);
  }

  // ===================== الكتالوج =====================
  Future<List<MedicineModel>> getCatalog() async {
    final db = await LocalDatabase.database;
    final maps = await db.query(_catalogTable, orderBy: 'name ASC');
    return maps.map((m) {
      return MedicineModel(
        id: m['id'] as String,
        name: m['name'] as String,
        type: MedicationType.values.firstWhere(
          (e) => e.name == m['type'],
          orElse: () => MedicationType.drug,
        ),
        withdrawalDays: m['withdrawal_days'] as int? ?? 0,
      );
    }).toList();
  }

  Future<void> seedCatalog(List<MedicineModel> medicines) async {
    final db = await LocalDatabase.database;
    await db.delete(_catalogTable);
    for (final m in medicines) {
      await db.insert(_catalogTable, {
        'id': m.id,
        'name': m.name,
        'type': m.type.name,
        'withdrawal_days': m.withdrawalDays,
      });
    }
  }

  MedicationModel _fromMap(Map<String, dynamic> map) {
    return MedicationModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      date: DateTime.parse(map['date'] as String),
      type: MedicationType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => MedicationType.drug,
      ),
      medicineName: map['medicine_name'] as String,
      dosage: map['dosage'] as String,
      administrationRoute: AdministrationRoute.values.firstWhere(
        (e) => e.name == map['administration_route'],
        orElse: () => AdministrationRoute.water,
      ),
      treatmentDays: map['treatment_days'] as int?,
      withdrawalDays: map['withdrawal_days'] as int? ?? 0,
      notes: map['notes'] as String?,
      workerId: map['worker_id'] as String,
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == map['sync_status'],
        orElse: () => SyncStatus.pending,
      ),
    );
  }
}