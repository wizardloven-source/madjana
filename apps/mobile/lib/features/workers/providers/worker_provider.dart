import 'package:core/core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:data/data.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/worker_repository_impl.dart';
import '../../auth/providers/auth_provider.dart';

/// Provider لمستودع العمال
final workerRepositoryProvider = Provider<WorkerRepository>((ref) {
  final supabase = Supabase.instance.client;
  final localDb = ref.watch(localDatabaseProvider);
  final authState = ref.watch(authProvider);
  
  return WorkerRepositoryImpl(
    supabase: supabase,
    localDb: localDb,
    currentUserId: authState.currentUser?.uid,
  );
});

/// Provider للعامل الحالي
final currentWorkerProvider = FutureProvider<WorkerModel?>((ref) async {
  final repo = ref.watch(workerRepositoryProvider);
  final authState = ref.watch(authProvider);
  final workerId = authState.currentUser?.uid;
  
  if (workerId == null) return null;
  
  return repo.getWorkerById(workerId);
});

/// Provider لكشوف الراتب للعامل المحدد
final workerSalarySlipsProvider = FutureProvider.family<List<SalarySlipModel>, String>((ref, workerId) async {
  final repo = ref.watch(workerRepositoryProvider);
  return repo.getWorkerSalarySlips(workerId);
});

/// Provider لطلبات السلف للعامل المحدد
final workerAdvanceRequestsProvider = FutureProvider.family<List<AdvanceRequestModel>, String>((ref, workerId) async {
  final repo = ref.watch(workerRepositoryProvider);
  return repo.getWorkerAdvanceRequests(workerId);
});

/// Provider لقائمة العمال (للمدير)
final allWorkersProvider = FutureProvider<List<WorkerModel>>((ref) async {
  final repo = ref.watch(workerRepositoryProvider);
  // TODO: تمرير farmId من حالة المصادقة
  return repo.getAllWorkers();
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
