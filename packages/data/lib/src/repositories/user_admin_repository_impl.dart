import 'package:core/core.dart';
import '../datasources/remote/supabase_user_admin_datasource.dart';

/// تنفيذ إدارة المستخدمين - للمدير فقط
class UserAdminRepositoryImpl implements UserAdminRepository {
  final SupabaseUserAdminDatasource _remoteDatasource;

  UserAdminRepositoryImpl({required SupabaseUserAdminDatasource remoteDatasource})
      : _remoteDatasource = remoteDatasource;

  @override
  Future<List<UserModel>> getUsers(String farmId) async {
    try {
      return await _remoteDatasource.getUsers(farmId);
    } catch (e) {
      throw Exception('تعذّر جلب المستخدمين - تأكد من الاتصال بالإنترنت');
    }
  }

  @override
  Future<UserModel> createUser({
    required String farmId,
    required String name,
    required String phone,
    required String pin,
    required UserRole role,
  }) async {
    try {
      return await _remoteDatasource.createUser(
        farmId: farmId,
        name: name,
        phone: phone,
        pin: pin,
        role: role,
      );
    } catch (e) {
      throw Exception('تعذّر إنشاء المستخدم (تأكد من عدم تكرار رقم الهاتف)');
    }
  }

  @override
  Future<void> updateUser({
    required String uid,
    String? name,
    String? phone,
    UserRole? role,
  }) async {
    try {
      await _remoteDatasource.updateUser(uid: uid, name: name, phone: phone, role: role);
    } catch (e) {
      throw Exception('تعذّر تعديل المستخدم');
    }
  }

  @override
  Future<void> resetPin({required String uid, required String newPin}) async {
    try {
      await _remoteDatasource.resetPin(uid: uid, newPin: newPin);
    } catch (e) {
      throw Exception('تعذّر إعادة تعيين الرمز السري');
    }
  }

  @override
  Future<void> deleteUser(String uid) async {
    try {
      await _remoteDatasource.deleteUser(uid);
    } catch (e) {
      throw Exception('تعذّر حذف المستخدم');
    }
  }
}
