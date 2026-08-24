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

/// إدارة المستخدمين - للمدير فقط
abstract class UserAdminRepository {
  Future<List<UserModel>> getUsers(String farmId);

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
}
