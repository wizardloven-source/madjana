import 'package:core/core.dart';
import '../datasources/local/daos/user_dao.dart';
import '../datasources/remote/supabase_user_admin_datasource.dart';

/// تنفيذ إدارة المستخدمين - للمدير فقط
///
/// يقرأ من السحابة أولاً ويزرع كاشاً محلياً، وعند تعذّر الاتصال
/// يعرض الكاش المحلي حتى لا تفشل شاشة "المستخدمون".
class UserAdminRepositoryImpl implements UserAdminRepository {
  final SupabaseUserAdminDatasource _remoteDatasource;
  final UserDao _userDao;

  UserAdminRepositoryImpl({
    required SupabaseUserAdminDatasource remoteDatasource,
    required UserDao userDao,
  })  : _remoteDatasource = remoteDatasource,
        _userDao = userDao;

  @override
  Future<List<UserModel>> getUsers(String farmId) async {
    try {
      final remote = await _remoteDatasource.getUsers(farmId);
      try {
        await _userDao.upsertAll(farmId, remote);
      } catch (_) {}
      return remote;
    } catch (_) {
      return _userDao.getByFarm(farmId);
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
    if (role == UserRole.manager) {
      final users = await getUsers(farmId);
      final existingManager = users.any((u) => u.role == UserRole.manager);
      if (existingManager) {
        throw Exception('يوجد مدير بالفعل لهذه المدجنة - لا يمكن إنشاء مدير آخر');
      }
    }
    try {
      final created = await _remoteDatasource.createUser(
        farmId: farmId,
        name: name,
        phone: phone,
        pin: pin,
        role: role,
      );
      await getUsers(farmId);
      return created;
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