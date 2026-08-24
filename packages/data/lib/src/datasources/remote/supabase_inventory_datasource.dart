import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// مصدر بيانات المخزون عبر Supabase
class SupabaseInventoryDatasource {
  final SupabaseClient _client;

  SupabaseInventoryDatasource(this._client);

  Future<List<InventoryItemModel>> getItems(String farmId) async {
    final data = await _client
        .from('inventory_items')
        .select()
        .eq('farm_id', farmId)
        .order('name');
    return (data as List)
        .map((e) =>
            InventoryItemModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<Map<String, dynamic>> insertItem(InventoryItemModel item) async {
    return Map<String, dynamic>.from(
      await _client
          .from('inventory_items')
          .insert(item.toJson())
          .select()
          .single(),
    );
  }

  Future<void> updateItem(InventoryItemModel item) async {
    final json = item.toJson()..remove('id');
    await _client.from('inventory_items').update(json).eq('id', item.id!);
  }

  Future<void> deleteItem(String id) async {
    await _client.from('inventory_items').delete().eq('id', id);
  }

  Future<void> insertTransaction(InventoryTransactionModel tx,
      {required double newQuantity}) async {
    await _client.from('inventory_transactions').insert(tx.toJson());
    await _client
        .from('inventory_items')
        .update({'quantity': newQuantity}).eq('id', tx.itemId);
  }

  Future<List<InventoryTransactionModel>> getTransactions(String itemId) async {
    final data = await _client
        .from('inventory_transactions')
        .select()
        .eq('item_id', itemId)
        .order('date');
    return (data as List)
        .map((e) => InventoryTransactionModel.fromJson(
            Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}
