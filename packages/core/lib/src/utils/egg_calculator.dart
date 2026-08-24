import '../constants/app_constants.dart';

/// دوال حساب البيض والتحويلات
class EggCalculator {
  /// حساب إجمالي البيض
  static int calculateTotal({
    required int cartons,
    required int trays,
    required int looseEggs,
  }) {
    return (cartons * AppConstants.eggsPerCarton) +
        (trays * AppConstants.eggsPerTray) +
        looseEggs;
  }

  /// تحويل البيض إلى كراتين/صحون/بيضات (التحويل التلقائي)
  static EggBreakdown normalize({
    required int cartons,
    required int trays,
    required int looseEggs,
  }) {
    // تحويل البيضات الزائدة إلى صحون
    int finalLoose = looseEggs;
    int finalTrays = trays;
    int finalCartons = cartons;

    if (finalLoose >= AppConstants.eggsPerTray) {
      finalTrays += finalLoose ~/ AppConstants.eggsPerTray;
      finalLoose = finalLoose % AppConstants.eggsPerTray;
    }

    // تحويل الصحون الزائدة إلى كراتين
    if (finalTrays >= AppConstants.traysPerCarton) {
      finalCartons += finalTrays ~/ AppConstants.traysPerCarton;
      finalTrays = finalTrays % AppConstants.traysPerCarton;
    }

    return EggBreakdown(
      cartons: finalCartons,
      trays: finalTrays,
      looseEggs: finalLoose,
    );
  }

  /// تحويل كيلو علف إلى عدد أكياس
  static double kgToBags(double kg) => kg / AppConstants.kgPerBag;

  /// تحويل أطنان إلى كيلو
  static double tonsToKg(double tons) => tons * AppConstants.kgPerTon;
}

/// نتيجة التحويل
class EggBreakdown {
  final int cartons;
  final int trays;
  final int looseEggs;

  const EggBreakdown({
    required this.cartons,
    required this.trays,
    required this.looseEggs,
  });

  int get total => EggCalculator.calculateTotal(
        cartons: cartons,
        trays: trays,
        looseEggs: looseEggs,
      );
}