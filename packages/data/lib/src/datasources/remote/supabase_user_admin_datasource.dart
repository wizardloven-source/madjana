import 'package:core/core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// إدارة المستخدمين عبر دوال admin_* في قاعدة البيانات - للمدير فقط
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
        'created_at': d['created_at'],
      });

  Future<List<UserModel>> getUsers(String farmId) async {
    final data = await _client.from('users').select().eq('farm_id', farmId);
    final users = (data as List)
        .map((e) => _fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    users.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return users;
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
  }) async {
    await _client.rpc(
      'admin_update_user',
      params: {
        'p_uid': uid,
        'p_name': name,
        'p_phone': phone,
        'p_role': role?.name,
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
