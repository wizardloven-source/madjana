import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// إدارة المستخدمين عبر دوال admin_* في قاعدة البيانات
///
/// الإنشاء/الحذف يمر عبر auth.users أيضاً (دوال SECURITY DEFINER)
/// حتى يعمل تسجيل الدخول الحقيقي بـ Supabase Auth
class SupabaseUserAdminDatasource {
  final SupabaseClient _client;

  SupabaseUserAdminDatasource(this._client);

  UserModel _fromMap(Map<String, dynamic> d) => UserModel.fromJson({
        'uid': d['id'],
        'name': d['name'],
        'phone': d['phone'],
        'role': d['role'],
        'farm_id': d['farm_id'],
        'is_active': d['is_active'],
        'created_at': d['created_at'],
      });

  /// جلب مستخدمي مزرعة محددة (manager)
  Future<List<UserModel>> getUsers(String farmId) async {
    final data = await _client.from('users').select().eq('farm_id', farmId);
    final users = (data as List)
        .map((e) => _fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    users.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return users;
  }

  /// جلب كل المستخدمين (system_admin فقط)
  Future<List<UserModel>> getAllUsers() async {
    final data = await _client.rpc('admin_select_all_users');
    if (data == null) return [];
    final users = (data as List)
        .map((e) => _fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    users.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return users;
  }

  /// جلب كل المداجن (system_admin فقط)
  Future<List<FarmModel>> getAllFarms() async {
    final data = await _client.rpc('admin_select_all_farms');
    if (data == null) return [];
    return (data as List)
        .map((e) => FarmModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// صحة المزامنة لكل المداجن (system_admin فقط) — SYNC CENTER
  Future<List<Map<String, dynamic>>> getSyncHealth({
    int onlineWindowMinutes = 5,
  }) async {
    final data = await _client.rpc(
      'admin_sync_health',
      params: {'p_online_window_minutes': onlineWindowMinutes},
    );
    if (data == null) return [];
    return (data as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// إنشاء مستخدم جديد (ينشئ حساب auth مقابل تلقائياً)
  Future<UserModel> createUser({
    required String farmId,
    required String name,
    required String phone,
    required String pin,
    required UserRole role,
  }) async {
    final data = await _client.rpc(
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
    await _client.rpc(
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

  /// إعادة تعيين PIN (تحدّث كلمة مرور Supabase Auth أيضاً)
  Future<void> resetPin({required String uid, required String newPin}) async {
    await _client.rpc(
      'admin_reset_pin',
      params: {'p_uid': uid, 'p_new_pin': newPin},
    );
  }

  Future<void> deleteUser(String uid) async {
    await _client.rpc('admin_delete_user', params: {'p_uid': uid});
  }
}
