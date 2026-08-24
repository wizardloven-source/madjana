import 'package:core/core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/worker_repository_impl.dart';

/// Provider لمستودع العمال
final workerRepositoryProvider = Provider<WorkerRepository>((ref) {
  return WorkerRepositoryImpl();
});

/// Provider لقائمة العمال (للمدير)
final allWorkersProvider = FutureProvider<List<WorkerModel>>((ref) async {
  final repo = ref.watch(workerRepositoryProvider);
  // TODO: تمرير farmId من حالة المصادقة
  return repo.getAllWorkers();
});

/// Provider لكشوف الراتب للعامل الحالي
final mySalarySlipsProvider = FutureProvider<List<SalarySlipModel>>((ref) async {
  final repo = ref.watch(workerRepositoryProvider);
  // TODO: الحصول على workerId من الجلسة
  // هذا مجرد مثال - يجب تحديثه بالبيانات الفعلية
  return [];
});

/// Provider لطلبات السلف للعامل الحالي
final myAdvanceRequestsProvider = FutureProvider<List<AdvanceRequestModel>>((ref) async {
  final repo = ref.watch(workerRepositoryProvider);
  // TODO: الحصول على workerId من الجلسة
  return [];
});

/// Provider لكشوف الراتب غير المدفوعة
final unpaidSalarySlipsProvider = FutureProvider<List<SalarySlipModel>>((ref) async {
  final repo = ref.watch(workerRepositoryProvider);
  return repo.getUnpaidSalarySlips();
});

/// Provider لجميع طلبات السلف (للمدير)
final allAdvanceRequestsProvider = FutureProvider<List<AdvanceRequestModel>>((ref) async {
  final repo = ref.watch(workerRepositoryProvider);
  return repo.getAllAdvanceRequests();
});
