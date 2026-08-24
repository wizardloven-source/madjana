import '../models/expense_model.dart';
import '../models/inventory_model.dart';

/// مستودع المصروفات - للمدير فقط
abstract class ExpenseRepository {
  Future<List<ExpenseModel>> getExpenses({
    required String farmId,
    DateTime? fromDate,
    DateTime? toDate,
  });

  Future<void> save(ExpenseModel expense);

  Future<void> delete(String id);

  /// إجمالي المصروفات ضمن فترة
  Future<double> getTotal({
    required String farmId,
    DateTime? fromDate,
    DateTime? toDate,
  });
}

/// مستودع المخزون - للمدير فقط
abstract class InventoryRepository {
  Future<List<InventoryItemModel>> getItems(String farmId);

  Future<void> saveItem(InventoryItemModel item);

  Future<void> deleteItem(String id);

  /// تعديل كمية عنصر (إدخال أو إخراج)
  Future<InventoryItemModel> adjustStock({
    required String itemId,
    required bool isInput,
    required double quantity,
    String? note,
  });

  Future<List<InventoryTransactionModel>> getTransactions(String itemId);
}
