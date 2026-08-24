import 'package:core/core.dart';
import '../datasources/local/daos/expense_dao.dart';
import '../datasources/remote/supabase_expense_datasource.dart';

/// تنفيذ مستودع المصروفات - للمدير فقط
///
/// القراءة: من الخادم مع تحديث الكاش المحلي، والرجوع للمحلي عند انقطاع الاتصال.
/// التعديل: يتطلب اتصالاً بالإنترنت.
class ExpenseRepositoryImpl implements ExpenseRepository {
  final ExpenseDao _localDao;
  final SupabaseExpenseDatasource _remoteDatasource;

  ExpenseRepositoryImpl({
    required ExpenseDao localDao,
    required SupabaseExpenseDatasource remoteDatasource,
  })  : _localDao = localDao,
        _remoteDatasource = remoteDatasource;

  @override
  Future<List<ExpenseModel>> getExpenses({
    required String farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    try {
      final expenses = await _remoteDatasource.getExpenses(
        farmId: farmId,
        fromDate: fromDate,
        toDate: toDate,
      );
      if (fromDate == null && toDate == null) {
        await _localDao.saveAll(expenses, farmId);
      }
      return expenses;
    } catch (_) {
      return _localDao.getAll(
        farmId: farmId,
        fromDate: fromDate,
        toDate: toDate,
      );
    }
  }

  @override
  Future<void> save(ExpenseModel expense) async {
    try {
      if (expense.id != null) {
        await _remoteDatasource.update(expense.id!, expense);
      } else {
        final saved = await _remoteDatasource.insert(expense);
        await _localDao.insert(ExpenseModel.fromJson(saved)
            .copyWith(syncStatus: SyncStatus.synced));
        return;
      }
      await _localDao.insert(expense.copyWith(syncStatus: SyncStatus.synced));
    } catch (_) {
      throw Exception('تعذّر حفظ المصروف - تأكد من الاتصال بالإنترنت');
    }
  }

  @override
  Future<void> delete(String id) async {
    try {
      await _remoteDatasource.delete(id);
      await _localDao.delete(id);
    } catch (_) {
      throw Exception('تعذّر حذف المصروف - تأكد من الاتصال بالإنترنت');
    }
  }

  @override
  Future<double> getTotal({
    required String farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final expenses = await getExpenses(
      farmId: farmId,
      fromDate: fromDate,
      toDate: toDate,
    );
    return expenses.fold<double>(0, (sum, e) => sum + e.amount);
  }
}
