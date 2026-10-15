import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import '../datasources/remote/supabase_partnership_datasource.dart';

/// تنفيذ الشراكة (W7.2/W7.3) — قراءة وكتابة مباشرة من السحابة.
///
/// `calculateDistribution` تُترجم أخطاء PostgREST إلى رسالة الاستثناء الحقيقية
/// (مثل `AUTHORIZATION_DENIED`/`INVALID_PERCENTAGES`). أما
/// `createDistribution`/`approveDistribution` فالترجمة تتم في الـdatasource
/// (`mapPartnershipFailure`) وتُرمى [SyncFailure] بكود ثابت — لذا نمرّرها كما هي.
class PartnershipRepositoryImpl implements PartnershipRepository {
  final SupabasePartnershipDatasource _remoteDatasource;

  PartnershipRepositoryImpl({
    required SupabasePartnershipDatasource remoteDatasource,
  }) : _remoteDatasource = remoteDatasource;

  static String _realMessage(Object e) {
    try {
      final msg = (e as dynamic).message as String?;
      if (msg != null && msg.trim().isNotEmpty) return msg.trim();
    } catch (e) {
      debugPrint('madjana: partnership message extract failed: $e');
    }
    return e.toString().replaceFirst('Exception: ', '');
  }

  @override
  Future<List<ProfitDistributionPreview>> calculateDistribution({
    required String farmId,
    required DateTime periodStart,
    required DateTime periodEnd,
    String? flockId,
  }) async {
    try {
      return await _remoteDatasource.calculateDistribution(
        farmId: farmId,
        periodStart: periodStart,
        periodEnd: periodEnd,
        flockId: flockId,
      );
    } catch (e) {
      throw Exception(_realMessage(e));
    }
  }

  @override
  Future<String> createDistribution({
    required String farmId,
    required DateTime periodStart,
    required DateTime periodEnd,
    String? flockId,
    double reserveAmount = 0,
    String? label,
    String? notes,
  }) {
    // الـdatasource يترجم أخطاء PostgREST إلى SyncFailure أصلاً — لا نلفّها.
    return _remoteDatasource.createDistribution(
      farmId: farmId,
      periodStart: periodStart,
      periodEnd: periodEnd,
      flockId: flockId,
      reserveAmount: reserveAmount,
      label: label,
      notes: notes,
    );
  }

  @override
  Future<void> approveDistribution({required String distributionId}) =>
      _remoteDatasource.approveDistribution(distributionId: distributionId);
}
