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
        'farm_ids': d['user_farms'] is List
            ? (d['user_farms'] as List)
                .map((e) =>
                    (Map<String, dynamic>.from(e as Map))['farm_id'].toString())
                .where((e) => e.isNotEmpty)
                .toList()
            : d['farm_ids'],
        'is_active': d['is_active'],
        'created_at': d['created_at'],
      });

  /// ط¬ظ„ط¨ ظ…ط³طھط®ط¯ظ…ظٹ ظ…ط²ط±ط¹ط© ظ…ط­ط¯ظ‘ط¯ط© (manager)
  ///
  /// الأعضاء: المرتبطون بالمدجنة عبر جدول الربط (متعدد-إلى-متعدد)
  /// مضافاً إليهم مديرو النظام (يظهرون في قائمة كل مدجنة).
  Future<List<UserModel>> getUsers(String farmId) async {
    final linkRows = await _api
        .from('user_farms')
        .select(columns: const ['user_id'])
        .eq('farm_id', farmId)
        .get();
    final ids = linkRows.map((e) => e['user_id'].toString()).toSet();

    final adminRows = await _api
        .from('users')
        .select(columns: const ['id'])
        .eq('role', 'system_admin')
        .get();
    for (final e in adminRows) {
      final id = e['id']?.toString();
      if (id != null && id.isNotEmpty) ids.add(id);
    }
    if (ids.isEmpty) return [];

    final data = await _api
        .from('users')
        .select()
        .inFilter('id', ids.toList())
        .get();
    final users = (data)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map((e) => UserModel.fromJson(<String, dynamic>{
          'uid': e['id'],
          'name': e['name'],
          'phone': e['phone'],
          'role': e['role'],
          'farm_id': e['farm_id'],
          'is_active': e['is_active'],
          'created_at': e['created_at'],
        }))
        .toList();
    users.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return users;
  }

  /// ط¬ظ„ط¨ ظƒظ„ ط§ظ„ظ…ط³طھط®ط¯ظ…ظٹظ† ظ…ط¹ ظ…ط¯ط§ط¬ظ†ظ‡ظ… (system_admin ظپظ‚ط·)
  Future<List<UserModel>> getAllUsers() async {
    final data = await _api.rpc('admin_select_all_users_with_farms');
    if (data == null) return [];
    final users = (data as List)
        .map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          final farmIds = (m['farm_ids'] as List? ?? const [])
              .map((e2) => e2.toString())
              .where((e2) => e2.isNotEmpty)
              .toList();
          return UserModel.fromJson({
            'uid': m['user_id'],
            'name': m['name'],
            'phone': m['phone'],
            'role': m['role'],
            'farm_id': m['active_farm_id'],
            'farm_ids': farmIds,
            'is_active': m['is_active'],
            'created_at': m['created_at'],
          });
        })
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

  /// إنشاء مدجنة جديدة مع مديرها (system_admin فقط)
  Future<FarmModel> createFarmWithManager({
    required String farmName,
    String? location,
    required String managerName,
    required String phone,
    required String pin,
  }) async {
    final data = await _api.rpc('create_farm_with_manager', params: {
      'p_farm_name': farmName,
      'p_location': location ?? '',
      'p_manager_name': managerName,
      'p_phone': phone,
      'p_pin': pin,
    });
    final map = Map<String, dynamic>.from(data as Map);
    return FarmModel(
      id: map['farm_id'] as String,
      name: farmName,
      location: location?.trim().isEmpty ?? true ? null : location!.trim(),
    );
  }

  /// إنشاء مدجنة فقط (بدون مدير) — يربط المستخدمون لاحقاً (system_admin فقط)
  Future<FarmModel> createFarm({
    required String farmName,
    String? location,
  }) async {
    final data = await _api.rpc('admin_create_farm', params: {
      'p_farm_name': farmName,
      'p_location': location,
    });
    return FarmModel.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// إضافة ربط مستخدم موجود بمدجنة (بدون تحويل) (system_admin فقط)
  Future<void> assignUserToFarm({
    required String uid,
    required String farmId,
  }) async {
    await _api.rpc('admin_assign_user_to_farm', params: {
      'p_uid': uid,
      'p_farm_id': farmId,
    });
  }

  /// فكّ ربط مستخدم بمدجنة محددة (system_admin فقط)
  Future<void> unassignUserFromFarm({
    required String uid,
    required String farmId,
  }) async {
    await _api.rpc('admin_unassign_user_from_farm', params: {
      'p_uid': uid,
      'p_farm_id': farmId,
    });
  }

  /// المداجن المرتبط بها المستخدم الحالي مع أسمائها (مبدّل المداجن)
  Future<List<FarmModel>> getCurrentUserFarms() async {
    final data = await _api.rpc('current_user_farms_with_names');
    if (data == null) return [];
    return (data as List)
        .map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          return FarmModel(
            id: m['id'].toString(),
            name: m['name']?.toString() ?? '',
          );
        })
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