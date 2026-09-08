import 'package:core/core.dart';
import '../datasources/local/daos/user_dao.dart';
import '../datasources/remote/supabase_user_admin_datasource.dart';

/// تنفيذ إدارة المستخدمين
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

  static String _realMessage(Object e) {
    try {
      final msg = (e as dynamic).message as String?;
      if (msg != null && msg.trim().isNotEmpty) return msg.trim();
    } catch (_) {}
    return e.toString().replaceFirst('Exception: ', '');
  }

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
  Future<List<UserModel>> getAllUsers() async {
    try {
      return await _remoteDatasource.getAllUsers();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<FarmModel>> getAllFarms() async {
    try {
      return await _remoteDatasource.getAllFarms();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<FarmModel> createFarmWithManager({
    required String farmName,
    String? location,
    required String managerName,
    required String phone,
    required String pin,
  }) async {
    try {
      return await _remoteDatasource.createFarmWithManager(
        farmName: farmName,
        location: location,
        managerName: managerName,
        phone: phone,
        pin: pin,
      );
    } catch (e) {
      throw Exception(_realMessage(e));
    }
  }

  @override
  Future<FarmModel> createFarm({
    required String farmName,
    String? location,
  }) async {
    try {
      return await _remoteDatasource.createFarm(
        farmName: farmName,
        location: location,
      );
    } catch (e) {
      throw Exception(_realMessage(e));
    }
  }

  @override
  Future<void> assignUserToFarm({
    required String uid,
    String? farmId,
  }) async {
    try {
      await _remoteDatasource.assignUserToFarm(uid: uid, farmId: farmId);
    } catch (e) {
      throw Exception(_realMessage(e));
    }
  }

  @override
  Future<List<SyncHealthEntry>> getSyncHealth({
    int onlineWindowMinutes = 5,
  }) async {
    try {
      final raw = await _remoteDatasource.getSyncHealth(
        onlineWindowMinutes: onlineWindowMinutes,
      );
      return raw
          .map((e) => SyncHealthEntry.fromJson(e))
          .toList();
    } catch (_) {
      return [];
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
      throw Exception(_realMessage(e));
    }
  }

  @override
  Future<void> updateUser({
    required String uid,
    String? name,
    String? phone,
    UserRole? role,
    bool? isActive,
  }) async {
    try {
      await _remoteDatasource.updateUser(
        uid: uid,
        name: name,
        phone: phone,
        role: role,
        isActive: isActive,
      );
    } catch (e) {
      throw Exception(_realMessage(e));
    }
  }

  @override
  Future<void> resetPin({required String uid, required String newPin}) async {
    try {
      await _remoteDatasource.resetPin(uid: uid, newPin: newPin);
    } catch (e) {
      throw Exception(_realMessage(e));
    }
  }

  @override
  Future<void> deleteUser(String uid) async {
    try {
      await _remoteDatasource.deleteUser(uid);
    } catch (e) {
      throw Exception(_realMessage(e));
    }
  }
}