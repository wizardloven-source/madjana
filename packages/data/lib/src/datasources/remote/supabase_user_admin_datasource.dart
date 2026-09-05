import 'package:core/core.dart';
import 'supabase_api.dart';

/// ط¥ط¯ط§ط±ط© ط§ظ„ظ…ط³طھط®ط¯ظ…ظٹظ† ط¹ط¨ط± ط¯ظˆط§ظ„ admin_* ظپظٹ ظ‚ط§ط¹ط¯ط© ط§ظ„ط¨ظٹط§ظ†ط§طھ
///
/// ط§ظ„ط¥ظ†ط´ط§ط،/ط§ظ„ط­ط°ظپ ظٹظ…ط± ط¹ط¨ط± auth.users ط£ظٹط¶ط§ظ‹ (ط¯ظˆط§ظ„ SECURITY DEFINER)
/// ط­طھظ‰ ظٹط¹ظ…ظ„ طھط³ط¬ظٹظ„ ط§ظ„ط¯ط®ظˆظ„ ط§ظ„ط­ظ‚ظٹظ‚ظٹ ط¨ظ€ Supabase Auth
class SupabaseUserAdminDatasource {
  final SupabaseApi _api;

  SupabaseUserAdminDatasource(this._api);

  UserModel _fromMap(Map<String, dynamic> d) => UserModel.fromJson({
        'uid': d['id'],
        'name': d['name'],
        'phone': d['phone'],
        'role': d['role'],
        'farm_id': d['farm_id'],
        'is_active': d['is_active'],
        'created_at': d['created_at'],
      });

  /// ط¬ظ„ط¨ ظ…ط³طھط®ط¯ظ…ظٹ ظ…ط²ط±ط¹ط© ظ…ط­ط¯ط¯ط© (manager)
  Future<List<UserModel>> getUsers(String farmId) async {
    final data = await _api.from('users').select().eq('farm_id', farmId).get();
    final users = (data)
        .map((e) => _fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    users.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return users;
  }

  /// ط¬ظ„ط¨ ظƒظ„ ط§ظ„ظ…ط³طھط®ط¯ظ…ظٹظ† (system_admin ظپظ‚ط·)
  Future<List<UserModel>> getAllUsers() async {
    final data = await _api.rpc('admin_select_all_users');
    if (data == null) return [];
    final users = (data as List)
        .map((e) => _fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    users.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return users;
  }

  /// ط¬ظ„ط¨ ظƒظ„ ط§ظ„ظ…ط¯ط§ط¬ظ† (system_admin ظپظ‚ط·)
  Future<List<FarmModel>> getAllFarms() async {
    final data = await _api.rpc('admin_select_all_farms');
    if (data == null) return [];
    return (data as List)
        .map((e) => FarmModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// طµط­ط© ط§ظ„ظ…ط²ط§ظ…ظ†ط© ظ„ظƒظ„ ط§ظ„ظ…ط¯ط§ط¬ظ† (system_admin ظپظ‚ط·) â€” SYNC CENTER
  Future<List<Map<String, dynamic>>> getSyncHealth({
    int onlineWindowMinutes = 5,
  }) async {
    final data = await _api.rpc(
      'admin_sync_health',
      params: {'p_online_window_minutes': onlineWindowMinutes},
    );
    if (data == null) return [];
    return (data as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// ط¥ظ†ط´ط§ط، ظ…ط³طھط®ط¯ظ… ط¬ط¯ظٹط¯ (ظٹظ†ط´ط¦ ط­ط³ط§ط¨ auth ظ…ظ‚ط§ط¨ظ„ طھظ„ظ‚ط§ط¦ظٹط§ظ‹)
  Future<UserModel> createUser({
    required String farmId,
    required String name,
    required String phone,
    required String pin,
    required UserRole role,
  }) async {
    final data = await _api.rpc(
      'admin_create_user',
      params: {
        'p_farm_id': farmId,
        'p_name': name,
        'p_phone': phone,
        'p_pin': pin,
        'p_role': role.name,
      },
    );
    return _fromMap(Map<String, dynamic>.from(data as Map));
  }

  Future<void> updateUser({
    required String uid,
    String? name,
    String? phone,
    UserRole? role,
    bool? isActive,
  }) async {
    await _api.rpc(
      'admin_update_user',
      params: {
        'p_uid': uid,
        'p_name': name,
        'p_phone': phone,
        'p_role': role?.name,
        'p_is_active': isActive,
      },
    );
  }

  /// ط¥ط¹ط§ط¯ط© طھط¹ظٹظٹظ† PIN (طھط­ط¯ظ‘ط« ظƒظ„ظ…ط© ظ…ط±ظˆط± Supabase Auth ط£ظٹط¶ط§ظ‹)
  Future<void> resetPin({required String uid, required String newPin}) async {
    await _api.rpc(
      'admin_reset_pin',
      params: {'p_uid': uid, 'p_new_pin': newPin},
    );
  }

  Future<void> deleteUser(String uid) async {
    await _api.rpc('admin_delete_user', params: {'p_uid': uid});
  }
}