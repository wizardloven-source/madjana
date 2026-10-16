import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'supabase_api.dart';

/// معاينات/كتابة الشراكة عبر Supabase (W7.2/W7.3).
///
/// * `calculateDistribution` تستدعي M24 `calculate_profit_distribution`
///   (SECURITY DEFINER، read-only) التي تُعاين حصص الشركاء دون كتابة أي صف.
/// * `createDistribution`/`approveDistribution` تستدعي M30
///   `create_profit_distribution`/`approve_profit_distribution` وتترجم أخطاء
///   PostgREST إلى [SyncFailure] بكود ثابت (`mapPartnershipFailure`).
class SupabasePartnershipDatasource {
  final SupabaseApi _api;

  SupabasePartnershipDatasource(this._api);

  /// معاينة توزيع أرباح مزرعة خلال [periodStart]..[periodEnd].
  ///
  /// [flockId] اختياري؛ تركه `null` يعني كامل المدجنة.
  Future<List<ProfitDistributionPreview>> calculateDistribution({
    required String farmId,
    required DateTime periodStart,
    required DateTime periodEnd,
    String? flockId,
  }) async {
    final data = await _api.rpc('calculate_profit_distribution', params: {
      'p_farm_id': farmId,
      'p_period_start': _date(periodStart),
      'p_period_end': _date(periodEnd),
      'p_flock_id': flockId,
    });
    if (data == null) return const [];
    return (data as List)
        .map((e) => ProfitDistributionPreview.fromJson(
              Map<String, dynamic>.from(e as Map),
            ))
        .toList();
  }

  /// يجلب رأس التوزيع المخزَّن المطابق للمزرعة/الفترة/القطيع أو `null`.
  ///
  /// نستعلم كل صفوف المزرعة/الفترة ثم نختار الصف المطابق للقطيع محلياً، لأن
  /// واجهة [SupabaseApi] لا تحمل فلتر `IS NULL` (حالة توزيع كامل المزرعة).
  /// القيد الفريد (المزرعة/القطيع/الفترة) يضمن صفاً واحداً لكل قطيع.
  Future<ProfitDistribution?> getDistribution({
    required String farmId,
    required DateTime periodStart,
    required DateTime periodEnd,
    String? flockId,
  }) async {
    final rows = await _api
        .from('profit_distributions')
        .select(columns: _distributionColumns)
        .eq('farm_id', farmId)
        .eq('period_start', _date(periodStart))
        .eq('period_end', _date(periodEnd))
        .order('created_at', ascending: false)
        .get();
    for (final row in rows) {
      if (row['flock_id'] == flockId) return ProfitDistribution.fromJson(row);
    }
    return null;
  }

  /// يُخزّن توزيعاً جديداً (M30) ويعيد معرّفه (uuid).
  ///
  /// يمرّر كل `p_*` صراحةً (بما فيها `p_flock_id`/`p_label`/`p_notes` = null)
  /// كي تُستدعى الدالة بتوقيعها الكامل لا بالافتراضيات الخاطئة.
  Future<String> createDistribution({
    required String farmId,
    required DateTime periodStart,
    required DateTime periodEnd,
    String? flockId,
    double reserveAmount = 0,
    String? label,
    String? notes,
  }) async {
    try {
      final data = await _api.rpc('create_profit_distribution', params: {
        'p_farm_id': farmId,
        'p_period_start': _date(periodStart),
        'p_period_end': _date(periodEnd),
        'p_flock_id': flockId,
        'p_reserve_amount': reserveAmount,
        'p_label': label,
        'p_notes': notes,
      });
      if (data is List) {
        if (data.isEmpty) {
          throw SyncFailure(
              'UNKNOWN', 'create_profit_distribution لم تُعِد معرّفاً');
        }
        return data.first.toString();
      }
      return data.toString();
    } catch (e) {
      throw mapPartnershipFailure(e);
    }
  }

  /// يعتمد توزيعاً `draft` (مدير النظام فقط) فيصبح `approved`.
  Future<void> approveDistribution({required String distributionId}) async {
    try {
      await _api.rpc('approve_profit_distribution',
          params: {'p_distribution_id': distributionId});
    } catch (e) {
      throw mapPartnershipFailure(e);
    }
  }
}

/// أعمدة رأس التوزيع التي تقرأها `getDistribution` (W7.3-UI).
const _distributionColumns = <String>[
  'id',
  'farm_id',
  'flock_id',
  'period_start',
  'period_end',
  'label',
  'status',
  'total_revenue',
  'total_expenses',
  'net_profit',
  'reserve_amount',
  'distributable_profit',
  'approved_at',
  'approved_by',
  'notes',
];

/// أكواد أخطاء دوال الشراكة كما تُطلقها القاعدة (M24/M30).
const _partnershipCodes = <String>[
  'AUTHORIZATION_DENIED',
  'INVALID_PERCENTAGES',
  'PARTNER_NOT_FOUND',
  'INVALID_STATUS_TRANSITION',
  'DISTRIBUTION_EXISTS',
  'DISTRIBUTION_NOT_FOUND',
  'NEGATIVE_NET_PROFIT',
  'INVALID_RESERVE',
  'INVALID_PERIOD',
  'INVALID_FARM',
  'FARM_NOT_FOUND',
  'FLOCK_NOT_FOUND',
  'FLOCK_FARM_MISMATCH',
  'NO_SESSION',
];

/// يحوّل خطأ PostgREST/الشبكة إلى [SyncFailure] بكود ثابت واضح.
///
/// رسالة Postgres تأتي بالشكل `CODE: وصف`؛ نستخرج الكود الأول المعروف ونحفظ
/// الرسالة الكاملة كـ[SyncFailure.message] بدل نصّ عام غامض.
SyncFailure mapPartnershipFailure(Object error) {
  if (error is SyncFailure) return error;
  final message = _postgrestMessage(error);
  final code = _partnershipCodes.firstWhere(
    (c) => message.contains(c),
    orElse: () => 'UNKNOWN',
  );
  return SyncFailure(code, message, error);
}

String _postgrestMessage(Object error) {
  try {
    final msg = (error as dynamic).message as String?;
    if (msg != null && msg.trim().isNotEmpty) return msg.trim();
  } catch (e) {
    // بلا getter message (خطأ شبكة/StateError) — نطبع السبب ونكمل للنصّ الكامل.
    debugPrint('madjana: partnership error message extract failed: $e');
  }
  return error.toString().replaceFirst('Exception: ', '');
}

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
