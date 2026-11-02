import 'package:sqflite/sqlite_api.dart';
import 'package:sqflite_common_arguments/sqflite_common_arguments.dart';

import '../../../../core.dart';
import '../dart/farm_model.dart';

/// DAO for managing farms table in local SQLite database.
/// Handles CRUD operations and enqueues changes for sync.
class FarmDao {
  final Database _db;

  FarmDao(this._db);

  /// Create the farms table if it doesn't exist.
  Future<void> createTable() async {
    await _db.execute('''
      CREATE TABLE IF NOT EXISTS farms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        farm_name TEXT,
        farm_code TEXT,
        farm_type TEXT,
        created_at TEXT,
        updated_at TEXT,
        feed_bag_weight_kg REAL NOT NULL DEFAULT 50.0,
        trays_per_bundle INTEGER NOT NULL DEFAULT 100 CHECK (trays_per_bundle > 0)
      )
    ''');
  }

  /// Insert a new farm and enqueue the change for sync.
  Future<int> insertFarm(FarmModel farm) async {
    final id = await _db.insert('farms', farm.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    // Enqueue change for sync queue
    await LocalDatabase.enqueueChange(
      operation: DatabaseOperation.insert,
      table: 'farms',
      recordId: id,
      payload: farm.toJson(),
    );
    return id;
  }

  /// Update an existing farm and enqueue the change for sync.
  Future<int> updateFarm(FarmModel farm) async {
    final rowsAffected = await _db.update(
      'farms',
      farm.toMap(),
      where: 'id = ?',
      whereArgs: [farm.id],
    );
    if (rowsAffected > 0) {
      // Enqueue change for sync queue
      await LocalDatabase.enqueueChange(
        operation: DatabaseOperation.update,
        table: 'farms',
        recordId: farm.id,
        payload: farm.toJson(),
      );
    }
    return rowsAffected;
  }

  /// Delete a farm by ID and enqueue the change for sync.
  Future<int> deleteFarm(String farmId) async {
    // Get farm data before deletion for enqueue
    final farm = await getFarmById(farmId);
    final rowsAffected = await _db.delete(
      'farms',
      where: 'id = ?',
      whereArgs: [farmId],
    );
    if (rowsAffected > 0 && farm != null) {
      // Enqueue change for sync queue (delete operation)
      await LocalDatabase.enqueueChange(
        operation: DatabaseOperation.delete,
        table: 'farms',
        recordId: farmId,
        payload: farm.toJson(),
      );
    }
    return rowsAffected;
  }

  /// Get a farm by ID.
  Future<FarmModel?> getFarmById(String farmId) async {
    final List<Map<String, dynamic>> maps = await _db.query(
      'farms',
      columns: [
        'id',
        'farm_name',
        'farm_code',
        'farm_type',
        'created_at',
        'updated_at',
        'feed_bag_weight_kg',
        'trays_per_bundle',
        'eggs_per_carton',
        'eggs_per_tray',
        'default_mortality_rate',
        'carton_low_threshold',
      ],
      where: 'id = ?',
      whereArgs: [farmId],
    );

    if (maps.isEmpty) return null;

    return FarmModel.fromMap(maps.first);
  }

  /// Get all farms.
  Future<List<FarmModel>> getAllFarms() async {
    final List<Map<String, dynamic>> maps = await _db.query(
      'farms',
      columns: [
        'id',
        'farm_name',
        'farm_code',
        'farm_type',
        'created_at',
        'updated_at',
        'feed_bag_weight_kg',
        'trays_per_bundle',
        'eggs_per_carton',
        'eggs_per_tray',
        'default_mortality_rate',
        'carton_low_threshold',
      ],
    );

    return maps.map((map) => FarmModel.fromMap(map)).toList();
  }

  /// Get farm settings including feed bag weight and trays per bundle.
  Future<Map<String, dynamic>> getFarmSettings(String farmId) async {
    final List<Map<String, dynamic>> maps = await _db.query(
      'farms',
      columns: [
        'feed_bag_weight_kg',
        'trays_per_bundle',
        'farm_name',
        'farm_code',
      ],
      where: 'id = ?',
      whereArgs: [farmId],
    );

    if (maps.isEmpty) {
      return {
        'feed_bag_weight_kg': 50.0,
        'trays_per_bundle': 100,
        'farm_name': '',
        'farm_code': '',
      };
    }

    final map = maps.first;
    return {
      'feed_bag_weight_kg': map['feed_bag_weight_kg'] ?? 50.0,
      'trays_per_bundle': map['trays_per_bundle'] ?? 100,
      'farm_name': map['farm_name'] ?? '',
      'farm_code': map['farm_code'] ?? '',
    };
  }

  /// Update feed bag weight for a farm.
  Future<int> updateFeedBagWeight(String farmId, double weight) async {
    return await _db.update(
      'farms',
      {'feed_bag_weight_kg': weight},
      where: 'id = ?',
      whereArgs: [farmId],
    );
  }

  /// Update trays per bundle for a farm.
  Future<int> updateTraysPerBundle(String farmId, int count) async {
    return await _db.update(
      'farms',
      {'trays_per_bundle': count},
      where: 'id = ?',
      whereArgs: [farmId],
    );
  }
}