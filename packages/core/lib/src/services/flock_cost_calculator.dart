import '../models/expense_model.dart';
import '../models/feed_received_model.dart';
import '../models/medication_model.dart';

/// تسوية مخزون (إدخال/إخراج) — مساهمة قيمة في تكلفة القطيع.
///
/// `flock_id == null` تعني تسوية على مستوى المزرعة، ولا تُحتسب لأي قطيع.
/// `unit_price == null` تعني كمية بلا سعر، والكمية بلا سعر ليست تكلفة
/// (docs/ACCOUNTING_RULES.md §5) ولا تُجمع.
class StockAdjustment {
  final String? flockId;
  final double deltaQty;
  final double? unitPrice;

  const StockAdjustment({
    this.flockId,
    required this.deltaQty,
    this.unitPrice,
  });
}

/// تفصيل تكلفة قطيع من المصادر الأربعة (docs/ACCOUNTING_RULES.md §6):
///
/// ```text
/// flockCost(X) =
///       SUM(expenses.amount              WHERE flock_id = X)
///     + SUM(feed_received.quantity_kg × price_per_kg WHERE flock_id = X)
///     + SUM(medications.cost             WHERE flock_id = X)
///     + SUM(stock_adjustments.delta_qty × unit_price WHERE flock_id = X)
/// ```
///
/// قيم المركبات موقّعة كما هي؛ يبقى `totalCost` غير سالب أبداً (مشبّك عند 0).
/// أي كمية بلا سعر (علف بلا `price_per_kg`، دواء بلا `cost` وبلا سعر مخزون،
/// تسوية بلا `unit_price`) تُحتسب صفراً وتُحصى في عداد `unpriced*` — تنبيه
/// مرئي للمدير بدل إخفاء المال الصامت.
class FlockCost {
  final double feedCost;
  final double medicationCost;
  final double expensesCost;
  final double stockAdjustmentCost;

  /// عدد شحنات العلف بلا سعر — لم تُدخل في [feedCost].
  final int unpricedShipments;

  /// عدد الأدوية التي لم يُحسم سعرها (لا `cost` ولا سعر مخزون) — صفر + تنبيه.
  final int unpricedMedications;

  /// عدد التسويات بلا `unit_price` — لم تُدخل في [stockAdjustmentCost].
  final int unpricedAdjustments;

  /// المجموع الكلي — مشبّك عند 0 (لا تكلفة سالبة أبداً).
  final double totalCost;

  const FlockCost({
    required this.feedCost,
    required this.medicationCost,
    required this.expensesCost,
    required this.stockAdjustmentCost,
    required this.unpricedShipments,
    required this.unpricedMedications,
    required this.unpricedAdjustments,
    required this.totalCost,
  });

  factory FlockCost.empty() => const FlockCost(
        feedCost: 0,
        medicationCost: 0,
        expensesCost: 0,
        stockAdjustmentCost: 0,
        unpricedShipments: 0,
        unpricedMedications: 0,
        unpricedAdjustments: 0,
        totalCost: 0,
      );
}

/// يفصّل تكلفة قطيع من بياناته الخام وفق §1–§6 في docs/ACCOUNTING_RULES.md.
class FlockCostCalculator {
  const FlockCostCalculator._();

  /// [`round4`] يتطابق مع دقة الأعمدة المالية `NUMERIC(19,4)`/`NUMERIC(12,4)`.
  static double _round4(double v) => (v * 10000).round() / 10000;

  /// [inventoryUnitPrices]: خرائط عنصر مخزون → سعر وحدة من حركة المخزون.
  /// تُستخدم فقط لدواء مرتبط بـ `inventoryItemId` (قاعدة §4).
  static FlockCost calculate({
    required String flockId,
    required Iterable<FeedReceivedModel> feedReceived,
    required Iterable<ExpenseModel> expenses,
    required Iterable<MedicationModel> medications,
    required Iterable<StockAdjustment> stockAdjustments,
    Map<String, double> inventoryUnitPrices = const {},
  }) {
    // ── 1) العلف: كمية × سعر، شحنات بلا سعر تُحصى ولا تُجمع ──────────────
    var feedCost = 0.0;
    var unpricedShipments = 0;
    for (final s in feedReceived) {
      if (s.flockId != flockId) continue;
      final price = s.pricePerKg;
      if (price == null) {
        unpricedShipments++;
        continue;
      }
      feedCost += s.quantityKg * price;
    }

    // ── 2) المصروف المباشر: سطر ينسب القطيع فقط؛ المزرعة (NULL) تُستبعد ──
    var expensesCost = 0.0;
    for (final e in expenses) {
      if (e.flockId == null || e.flockId != flockId) continue;
      expensesCost += e.amount < 0 ? 0 : e.amount;
    }

    // ── 3) الأدوية: أولوية §4 — السعر من المخزون ثم `cost` ثم 0 + تنبيه ──
    var medicationCost = 0.0;
    var unpricedMedications = 0;
    for (final m in medications) {
      if (m.flockId != flockId) continue;
      var cost = m.cost;
      if (m.inventoryItemId != null) {
        final price = inventoryUnitPrices[m.inventoryItemId];
        if (price != null) cost = price;
      }
      if (cost == null) {
        unpricedMedications++;
        continue;
      }
      medicationCost += cost < 0 ? 0 : cost;
    }

    // ── 4) تسويات المخزون: delta_qty × unit_price (موقّعة) ───────────────
    var stockAdjustmentCost = 0.0;
    var unpricedAdjustments = 0;
    for (final a in stockAdjustments) {
      if (a.flockId != flockId) continue;
      final price = a.unitPrice;
      if (price == null) {
        unpricedAdjustments++;
        continue;
      }
      stockAdjustmentCost += a.deltaQty * price;
    }

    final feedR = _round4(feedCost);
    final medR = _round4(medicationCost);
    final expR = _round4(expensesCost);
    final adjR = _round4(stockAdjustmentCost);
    final raw = feedR + medR + expR + adjR;

    return FlockCost(
      feedCost: feedR,
      medicationCost: medR,
      expensesCost: expR,
      stockAdjustmentCost: adjR,
      unpricedShipments: unpricedShipments,
      unpricedMedications: unpricedMedications,
      unpricedAdjustments: unpricedAdjustments,
      totalCost: raw < 0 ? 0.0 : _round4(raw),
    );
  }
}