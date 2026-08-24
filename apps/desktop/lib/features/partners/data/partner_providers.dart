import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'package:data/data.dart';

/// Provider لمستودع الشركاء
final partnerRepositoryProvider = Provider<PartnerRepository>((ref) {
  // سيتم تهيئته من main.dart
  throw UnimplementedError('يجب تهيئة partnerRepository في main.dart');
});

/// Provider لجلب جميع الشركاء
final allPartnersProvider = FutureProvider<List<PartnerModel>>((ref) async {
  final repository = ref.watch(partnerRepositoryProvider);
  return repository.getAllPartners();
});

/// Provider لجلب شركاء مدجنة معينة
final partnersByFarmProvider = FutureProvider.family<List<PartnerModel>, String>((ref, farmId) async {
  final repository = ref.watch(partnerRepositoryProvider);
  return repository.getPartnersByFarm(farmId);
});

/// Provider لجلب تفاصيل شريك معين
final partnerDetailProvider = FutureProvider.family<PartnerModel?, String>((ref, partnerId) async {
  final repository = ref.watch(partnerRepositoryProvider);
  return repository.getPartnerById(partnerId);
});

/// Provider لجلب علاقات الشريك بالمزارع
final partnerRelationsProvider = FutureProvider.family<List<PartnerFarmRelation>, String>((ref, partnerId) async {
  final repository = ref.watch(partnerRepositoryProvider);
  return repository.getPartnerFarmRelations(partnerId);
});

/// Provider لجلب معاملات الشريك
final partnerTransactionsProvider = FutureProvider.family<List<PartnerTransaction>, String>((ref, partnerId) async {
  final repository = ref.watch(partnerRepositoryProvider);
  return repository.getPartnerTransactions(partnerId);
});

/// Provider لجلب رصيد الشريك
final partnerBalanceProvider = FutureProvider.family<double, String>((ref, partnerId) async {
  final repository = ref.watch(partnerRepositoryProvider);
  return repository.getPartnerBalance(partnerId);
});

/// Provider لجلب تنبيهات العقود
final contractAlertsProvider = FutureProvider<List<PartnerContractAlert>>((ref) async {
  final repository = ref.watch(partnerRepositoryProvider);
  return repository.getContractAlerts();
});

/// Provider لتقرير الشريك
final partnerReportProvider = FutureProvider.family<PartnerReport, String>((ref, partnerId) async {
  final repository = ref.watch(partnerRepositoryProvider);
  return repository.getPartnerReport(partnerId: partnerId);
});

/// Provider لحالة التحميل والخطأ
class PartnerState {
  final bool isLoading;
  final String? error;
  final PartnerModel? partner;

  PartnerState({
    this.isLoading = false,
    this.error,
    this.partner,
  });

  PartnerState copyWith({
    bool? isLoading,
    String? error,
    PartnerModel? partner,
  }) {
    return PartnerState(
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
      partner: partner ?? this.partner,
    );
  }
}

/// Notifier لإدارة حالة الشريك
class PartnerNotifier extends StateNotifier<PartnerState> {
  final PartnerRepository _repository;

  PartnerNotifier(this._repository) : super(PartnerState());

  Future<void> loadPartner(String partnerId) async {
    state = state.copyWith(isLoading: true, error: null);
    
    try {
      final partner = await _repository.getPartnerById(partnerId);
      state = state.copyWith(partner: partner, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: e.toString(), isLoading: false);
    }
  }

  Future<void> savePartner(PartnerModel partner) async {
    state = state.copyWith(isLoading: true, error: null);
    
    try {
      await _repository.savePartner(partner);
      state = state.copyWith(partner: partner, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: e.toString(), isLoading: false);
      rethrow;
    }
  }

  Future<void> deletePartner(String partnerId) async {
    state = state.copyWith(isLoading: true, error: null);
    
    try {
      await _repository.deletePartner(partnerId);
      state = PartnerState();
    } catch (e) {
      state = state.copyWith(error: e.toString(), isLoading: false);
      rethrow;
    }
  }

  Future<void> distributeProfit({
    required String partnerId,
    required String farmId,
    required double amount,
    required String description,
  }) async {
    try {
      await _repository.distributeProfit(
        partnerId: partnerId,
        farmId: farmId,
        amount: amount,
        description: description,
      );
    } catch (e) {
      rethrow;
    }
  }

  Future<void> recordWithdrawal({
    required String partnerId,
    required double amount,
    String? description,
    String? paymentMethod,
  }) async {
    try {
      await _repository.recordWithdrawal(
        partnerId: partnerId,
        amount: amount,
        description: description,
        paymentMethod: paymentMethod,
      );
    } catch (e) {
      rethrow;
    }
  }
}

final partnerNotifierProvider = StateNotifierProvider<PartnerNotifier, PartnerState>((ref) {
  final repository = ref.watch(partnerRepositoryProvider);
  return PartnerNotifier(repository);
});
