import 'package:core/core.dart';
import '../datasources/remote/supabase_withdrawal_datasource.dart';

/// تنفيذ سحوبات الشركاء (W7.4) — قراءة وكتابة مباشرة من السحابة.
///
/// كل العمليات تمرّ عبر [SupabaseWithdrawalDatasource] التي تترجم أخطاء
/// PostgREST إلى [SyncFailure] بكود ثابت — نمرّرها كما هي دون لفّها.
class PartnerWithdrawalRepositoryImpl implements PartnerWithdrawalRepository {
  final SupabaseWithdrawalDatasource _remoteDatasource;

  PartnerWithdrawalRepositoryImpl({
    required SupabaseWithdrawalDatasource remoteDatasource,
  }) : _remoteDatasource = remoteDatasource;

  @override
  Future<List<PartnerWithdrawal>> getWithdrawals({
    String? partnerId,
    String? farmId,
    PartnerWithdrawalStatus? status,
  }) =>
      _remoteDatasource.getWithdrawals(
        partnerId: partnerId,
        farmId: farmId,
        status: status,
      );

  @override
  Future<PartnerWithdrawal> createWithdrawal({
    required String partnerId,
    required String farmId,
    required double amount,
    required String requestedBy,
    String? distributionId,
    String? reason,
    String currency = 'dollar',
    String? notes,
  }) =>
      _remoteDatasource.createWithdrawal(
        partnerId: partnerId,
        farmId: farmId,
        amount: amount,
        requestedBy: requestedBy,
        distributionId: distributionId,
        reason: reason,
        currency: currency,
        notes: notes,
      );

  @override
  Future<void> approveWithdrawal({
    required String withdrawalId,
    required String approverId,
  }) =>
      _remoteDatasource.approveWithdrawal(
        withdrawalId: withdrawalId,
        approverId: approverId,
      );

  @override
  Future<void> rejectWithdrawal({
    required String withdrawalId,
    required String rejectionReason,
  }) =>
      _remoteDatasource.rejectWithdrawal(
        withdrawalId: withdrawalId,
        rejectionReason: rejectionReason,
      );

  @override
  Future<void> markPaid({
    required String withdrawalId,
    String? paymentMethod,
  }) =>
      _remoteDatasource.markPaid(
        withdrawalId: withdrawalId,
        paymentMethod: paymentMethod,
      );

  @override
  Future<void> cancelWithdrawal({
    required String withdrawalId,
    String? notes,
  }) =>
      _remoteDatasource.cancelWithdrawal(
        withdrawalId: withdrawalId,
        notes: notes,
      );

  @override
  Future<List<PartnerAuditEntry>> getPartnerAudit({
    String? farmId,
    String? partnerId,
  }) =>
      _remoteDatasource.getPartnerAudit(farmId: farmId, partnerId: partnerId);

  @override
  Future<PartnerSummary> getPartnerSummary({required String partnerId}) =>
      _remoteDatasource.getPartnerSummary(partnerId: partnerId);
}
