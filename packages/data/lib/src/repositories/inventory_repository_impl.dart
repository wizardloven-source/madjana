import 'package:core/core.dart';
import 'package:uuid/uuid.dart';
import '../datasources/local/daos/inventory_dao.dart';
import '../datasources/remote/supabase_inventory_datasource.dart';

/// تنفيذ مستودع المخزون - للمدير فقط
///
/// القراءة: من الخادم مع تحديث الكاش المحلي، والرجوع للمحلي عند انقطاع الاتصال.
/// التعديل: يتطلب اتصالاً بالإنترنت.
class InventoryRepositoryImpl implements InventoryRepository {
  final InventoryDao _localDao;
  final SupabaseInventoryDatasource _remoteDatasource;
  static const _uuid = Uuid();

  InventoryRepositoryImpl({
    required InventoryDao localDao,
    required SupabaseInventoryDatasource remoteDatasource,
  })  : _localDao = localDao,
        _remoteDatasource = remoteDatasource;

  @override
  Future<List<InventoryItemModel>> getItems(String farmId) async {
    try {
      final items = await _remoteDatasource.getItems(farmId);
      for (final item in items) {
        if (item.id != null) {
          await _localDao.saveItem(item);
        }
      }
      return items;
    } catch (_) {
      return _localDao.getItems(farmId);
    }
  }

  @override
  Future<void> saveItem(InventoryItemModel item) async {
    await _localDao.saveItem(item);
    try {
      if (item.id != null) {
        await _remoteDatasource.updateItem(item);
      } else {
        final saved = await _remoteDatasource.insertItem(item);
        await _localDao.saveItem(InventoryItemModel.fromJson(saved));
      }
    } catch (_) {
      // Offline: saved locally, will sync later
    }
  }

  @override
  Future<void> deleteItem(String id) async {
    await _localDao.deleteItem(id);
    try {
      await _remoteDatasource.deleteItem(id);
    } catch (_) {
      // Offline: deleted locally
    }
  }

  @override
  Future<InventoryItemModel> adjustStock({
    required String itemId,
    required bool isInput,
    required double quantity,
    String? note,
  }) async {
    final current = await _localDao.getById(itemId);
    if (current == null) {
      throw Exception('العنصر غير موجود');
    }

    final newQuantity =
        isInput ? current.quantity + quantity : current.quantity - quantity;
    if (!isInput && newQuantity < 0) {
      throw Exception('الكمية المطلوبة أكبر من المتوفر');
    }

    final tx = InventoryTransactionModel(
      id: _uuid.v4(),
      itemId: itemId,
      date: DateTime.now(),
      isInput: isInput,
      quantity: quantity,
      note: note,
    );

    final result =
        current.copyWith(quantity: newQuantity, notes: note ?? current.notes);
    await _localDao.saveItem(result);

    try {
      await _remoteDatasource.insertTransaction(tx, newQuantity: newQuantity);
    } catch (_) {
      // Offline: saved locally
    }

    return result;
  }

  @override
  Future<List<InventoryTransactionModel>> getTransactions(String itemId) async {
    try {
      return await _remoteDatasource.getTransactions(itemId);
    } catch (_) {
      return _localDao.getTransactions(itemId);
    }
  }
}
