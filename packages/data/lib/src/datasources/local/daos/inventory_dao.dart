import 'package:core/core.dart';
import 'package:data/data.dart';
import 'package:moor/moor.dart';

part 'inventory_dao.g.dart';

@UseDao(tables: [DatabaseSchema.inventoryItems, DatabaseSchema.inventoryTransactions])
class InventoryDao extends DatabaseAccessor<AppDatabase> with _$InventoryDaoMixin {
  InventoryDao(AppDatabase db) : super(db);

  // Inventory Items
  Future<List<InventoryItem>> getAllItems(String farmId) {
    return (select(inventoryItems)..where((t) => t.farmId.equals(farmId))).get();
  }

  Future<InventoryItem?> getItemById(String id) {
    return (select(inventoryItems)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<List<InventoryItem>> getLowStockItems(String farmId) {
    return (select(inventoryItems)..where((t) => t.farmId.equals(farmId) & t.quantity.isSmallerOrEqualValue(t.minStockLevel))).get();
  }

  Future<List<InventoryItem>> getExpiringItems(String farmId, int days) {
    final expiryDate = DateTime.now().add(Duration(days: days));
    return (select(inventoryItems)..where((t) => t.farmId.equals(farmId) & t.expiryDate.isNotNull() & t.expiryDate.isSmallerOrEqualValue(expiryDate))).get();
  }

  Future<int> insertItem(InventoryItemCompanion item) {
    return into(inventoryItems).insert(item);
  }

  Future<bool> updateItem(InventoryItem item) {
    return update(inventoryItems).replace(item);
  }

  Future<void> deleteItem(String id) {
    (delete(inventoryItems)..where((t) => t.id.equals(id))).go();
  }

  // Inventory Transactions
  Future<List<InventoryTransaction>> getItemTransactions(String itemId) {
    return (select(inventoryTransactions)..where((t) => t.itemId.equals(itemId))).get();
  }

  Future<int> addTransaction(InventoryTransactionCompanion transaction) {
    return into(inventoryTransactions).insert(transaction);
  }

  // Search by barcode
  Future<InventoryItem?> getItemByBarcode(String barcode) {
    return (select(inventoryItems)..where((t) => t.barcode.equals(barcode))).getSingleOrNull();
  }
}

// DAO for Health Logs
@UseDao(tables: [DatabaseSchema.healthLogs])
class HealthLogDao extends DatabaseAccessor<AppDatabase> with _$HealthLogDaoMixin {
  HealthLogDao(AppDatabase db) : super(db);

  Future<List<HealthLog>> getLogsByFlock(String flockId) {
    return (select(healthLogs)..where((t) => t.flockId.equals(flockId))).get();
  }

  Future<List<HealthLog>> getRecentLogs(String farmId, int limit) {
    return (select(healthLogs)..where((t) => t.farmId.equals(farmId))..orderBy([(t) => OrderingTerm.desc(t.logDate)])..limit(limit)).get();
  }

  Future<int> insertLog(HealthLogCompanion log) {
    return into(healthLogs).insert(log);
  }

  Future<bool> updateLog(HealthLog log) {
    return update(healthLogs).replace(log);
  }
}

// DAO for Worker Shifts
@UseDao(tables: [DatabaseSchema.workerShifts])
class WorkerShiftDao extends DatabaseAccessor<AppDatabase> with _$WorkerShiftDaoMixin {
  WorkerShiftDao(AppDatabase db) : super(db);

  Future<List<WorkerShift>> getShiftsByWorker(String workerName) {
    return (select(workerShifts)..where((t) => t.workerName.equals(workerName))).get();
  }

  Future<List<WorkerShift>> getShiftsByDate(String farmId, DateTime date) {
    final start = DateTime(date.year, date.month, date.day);
    final end = start.add(Duration(days: 1));
    return (select(workerShifts)..where((t) => t.farmId.equals(farmId) & t.shiftDate.isBetweenValues(start, end))).get();
  }

  Future<int> insertShift(WorkerShiftCompanion shift) {
    return into(workerShifts).insert(shift);
  }

  Future<bool> updateShift(WorkerShift shift) {
    return update(workerShifts).replace(shift);
  }
}
