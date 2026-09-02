import '../constants/enums.dart';
import '../models/farm_model.dart';
import '../models/flock_model.dart';
import '../models/user_model.dart';

/// مستودع القطعان - إدارة كاملة للمدير
abstract class FlockRepository {
  /// جلب قطعان المزرعة
  Future<List<FlockModel>> getFlocks(String farmId, {bool includeEnded});

  /// إنشاء قطيع جديد
  Future<void> createFlock(FlockModel flock);

  /// تعديل بيانات قطيع
  Future<void> updateFlock(FlockModel flock);

  /// إنهاء دورة قطيع
  Future<void> endFlock(String flockId);
}

/// إدارة المستخدمين
abstract class UserAdminRepository {
  Future<List<UserModel>> getUsers(String farmId);

  /// جلب كل المستخدمين (system_admin فقط)
  Future<List<UserModel>> getAllUsers();

  /// جلب كل المداجن (system_admin فقط)
  Future<List<FarmModel>> getAllFarms();

  Future<UserModel> createUser({
    required String farmId,
    required String name,
    required String phone,
    required String pin,
    required UserRole role,
  });

  Future<void> updateUser({
    required String uid,
    String? name,
    String? phone,
    UserRole? role,
    bool? isActive,
  });

  Future<void> resetPin({required String uid, required String newPin});

  Future<void> deleteUser(String uid);
}

/// إدارة بيانات المدجنة والإعدادات - للمدير
abstract class FarmRepository {
  Future<FarmModel> getFarm(String farmId);

  Future<void> updateFarm(FarmModel farm);

  /// رمز العملة المعروض (مثل: ل.س، $)
  Future<String> getCurrency();

  Future<void> setCurrency(String symbol);

  /// إعدادات النظام
  Future<double> getFeedBagWeightKg();
  Future<void> setFeedBagWeightKg(double weightKg);
  
  Future<int> getEggsPerCarton();
  Future<void> setEggsPerCarton(int count);
  
  Future<int> getEggsPerTray();
  Future<void> setEggsPerTray(int count);
  
  Future<double> getDefaultMortalityRate();
  Future<void> setDefaultMortalityRate(double rate);
}
