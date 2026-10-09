import 'package:core/core.dart';
import 'package:flutter/foundation.dart' show debugPrint;
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
    } catch (e) {
      debugPrint('madjana: getExpenses offline fallback: $e');
      return _localDao.getAll(
        farmId: farmId,
        fromDate: fromDate,
        toDate: toDate,
      );
    }
  }

  @override
  Future<void> save(ExpenseModel expense) async {
    if (expense.id == null) {
      // عيّن معرّفاً موحّداً للعملية محلياً وبعيداً حتى لا يتكرر المصروف:
      // كان الخادم ينشئ معرّفاً مختلفاً عند الرفع الفوري، ثم يُعيد syncNow رفع
      // سجل sync_queue بنفس المعرّف المحلي → صف مكرر على الخادم.
      final localId = await _localDao.insert(expense.copyWith(syncStatus: SyncStatus.pending));
      try {
        final saved = await _remoteDatasource.insert(expense.copyWith(id: localId));
        await _localDao.update(localId, ExpenseModel.fromJson(saved).copyWith(syncStatus: SyncStatus.synced));
      } catch (e) {
        debugPrint('madjana: expense remote insert offline: $e');
        // Offline: saved locally with pending status
      }
    } else {
      await _localDao.update(expense.id!, expense.copyWith(syncStatus: SyncStatus.pending));
      try {
        await _remoteDatasource.update(expense.id!, expense);
        await _localDao.update(expense.id!, expense.copyWith(syncStatus: SyncStatus.synced));
      } catch (e) {
        debugPrint('madjana: expense remote update offline: $e');
        // Offline: saved locally with pending status
      }
    }
  }

  @override
  Future<void> delete(String id) async {
    await _localDao.delete(id);
    try {
      await _remoteDatasource.delete(id);
    } catch (e) {
      debugPrint('madjana: expense remote delete offline: $e');
      // Offline: deleted locally, will sync later
    }
  }

  /// رفع المصروفات المعلقة (المحفوظة محلياً أثناء الانقطاع) إلى السحابة
  @override
  Future<void> syncPendingRecords() async {
    final pending = await _localDao.getPendingModels();
    if (pending.isEmpty) return;

    for (final expense in pending) {
      final id = expense.id;
      if (id == null) continue;
      try {
        await _remoteDatasource.insert(expense);
        await _localDao.updateSyncStatus(id, SyncStatus.synced);
      } catch (e) {
        debugPrint('madjana: expense sync pending failed: $e');
        // يبقى pending للمحاولة التالية
      }
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
