import 'package:core/core.dart';
import 'supabase_api.dart';

/// ظ…طµط¯ط± ط¨ظٹط§ظ†ط§طھ ط§ظ„ظ…ط®ط²ظˆظ† ط¹ط¨ط± Supabase
class SupabaseInventoryDatasource {
  final SupabaseApi _api;

  SupabaseInventoryDatasource(this._api);

  Future<List<InventoryItemModel>> getItems(String farmId) async {
    final data = await _api
        .from('inventory_items')
        .select()
        .eq('farm_id', farmId)
        .order('name')
        .get();
    return (data)
        .map((e) =>
            InventoryItemModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<Map<String, dynamic>> insertItem(InventoryItemModel item) async {
    return _api
        .from('inventory_items')
        .insert(item.toJson())
        .select()
        .single();
  }

  Future<void> updateItem(InventoryItemModel item) async {
    final json = item.toJson()..remove('id');
    await _api.from('inventory_items').update(json).eq('id', item.id!).run();
  }

  Future<void> deleteItem(String id) async {
    await _api.from('inventory_items').delete().eq('id', id).run();
  }

  Future<void> insertTransaction(InventoryTransactionModel tx,
      {required double newQuantity}) async {
    await _api.from('inventory_transactions').insert(tx.toJson()).run();
    await _api
        .from('inventory_items')
        .update({'quantity': newQuantity}).eq('id', tx.itemId)
        .run();
  }

  Future<List<InventoryTransactionModel>> getTransactions(String itemId) async {
    final data = await _api
        .from('inventory_transactions')
        .select()
        .eq('item_id', itemId)
        .order('date')
        .get();
    return (data)
        .map((e) => InventoryTransactionModel.fromJson(
            Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}