import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

/// واجهة طبقة Supabase المُستخدمة في المصادر البعيدة.
///
/// تفصل المصادر عن التنفيذ الفعلي (SupabaseClient) حتى يمكن اختبار
/// عقودها (أسماء الجداول، الأعمدة، المرشّحات، دوال RPC، Storage)
/// عبر تنفيذ مزيّف محلي بدلاً من الاتصال بسيرفر حقيقي.
abstract interface class SupabaseApi {
  /// بناء استعلام على جدول معيّن.
  RemoteTable from(String table);

  /// استدعاء دالة في قاعدة البيانات (RPC).
  Future<dynamic> rpc(String name, {Map<String, dynamic>? params});

  /// واجهة تخزين الملفات.
  SupabaseStorageApi get storage;
}

/// مدخل الجدول: يختار بين القراءة (select) والكتابة (insert/update/delete).
abstract interface class RemoteTable {
  RemoteRead select({List<String> columns = const []});

  /// صف واحد (Map) أو مجموعة صفوف (List of Maps) — كما يقبلها Supabase.
  RemoteMutation insert(Object values, {String? onConflict});
  RemoteMutation upsert(Object values, {String? onConflict});
  RemoteMutation update(Map<String, dynamic> values);
  RemoteMutation delete();
}

/// استعلام قراءة قابل للتسلسل مع محطّات جلب البيانات.
abstract interface class RemoteRead {
  RemoteRead eq(String column, dynamic value);
  RemoteRead gte(String column, dynamic value);
  RemoteRead lte(String column, dynamic value);
  RemoteRead order(String column, {bool ascending = true});
  RemoteRead limit(int count);
  Future<List<Map<String, dynamic>>> get();
  Future<Map<String, dynamic>?> maybeSingle();
  Future<Map<String, dynamic>> single();
}

/// عملية كتابة (insert/update/delete/upsert) مع محطّة تنفيذ أو جلب العمود الراجع.
abstract interface class RemoteMutation {
  RemoteMutation eq(String column, dynamic value);
  Future<void> run();

  /// طلب الأعمدة الراجعة (RETURNING) بعد insert/upsert.
  RemoteRead select([List<String> columns = const []]);
}

/// واجهة تخزين الملفات (Supabase Storage).
abstract interface class SupabaseStorageApi {
  Future<String> upload(
    String bucket,
    String path,
    File file, {
    String cacheControl = '3600',
    bool upsert = false,
    String? contentType,
  });
  String getPublicUrl(String bucket, String path);
  Future<void> remove(String bucket, String path);
}

/// محوّل من SupabaseClient الحقيقي إلى [SupabaseApi].
class SupabaseClientApiAdapter implements SupabaseApi {
  final SupabaseClient _client;

  SupabaseClientApiAdapter(this._client);

  @override
  RemoteTable from(String table) => _TableAdapter(_client.from(table));

  @override
  Future<dynamic> rpc(String name, {Map<String, dynamic>? params}) =>
      _client.rpc(name, params: params);

  @override
  SupabaseStorageApi get storage => _StorageAdapter(_client.storage);
}

class _TableAdapter implements RemoteTable {
  final SupabaseQueryBuilder _builder;

  _TableAdapter(this._builder);

  @override
  RemoteRead select({List<String> columns = const []}) =>
      _ReadAdapter(_builder.select(columns.isEmpty ? '*' : columns.join(',')));

  @override
  RemoteMutation insert(Object values, {String? onConflict}) =>
      _MutationAdapter(_builder.insert(_toList(values)));

  @override
  RemoteMutation upsert(Object values, {String? onConflict}) =>
      _MutationAdapter(
          _builder.upsert(_toList(values), onConflict: onConflict));

  @override
  RemoteMutation update(Map<String, dynamic> values) =>
      _MutationAdapter(_builder.update(values));

  @override
  RemoteMutation delete() => _MutationAdapter(_builder.delete());
}

List<Map<String, dynamic>> _toList(Object values) =>
    values is List ? values.cast<Map<String, dynamic>>() : [values as Map<String, dynamic>];

class _ReadAdapter implements RemoteRead {
  /// يحمل [PostgrestFilterBuilder] للقراءة أو [PostgrestTransformBuilder]
  /// لأعمدة RETURNING — يشتركان في نفس الواجهة سلوكياً.
  dynamic _builder;

  _ReadAdapter(this._builder);

  @override
  RemoteRead eq(String column, dynamic value) {
    _builder = _builder.eq(column, value);
    return this;
  }

  @override
  RemoteRead gte(String column, dynamic value) {
    _builder = _builder.gte(column, value);
    return this;
  }

  @override
  RemoteRead lte(String column, dynamic value) {
    _builder = _builder.lte(column, value);
    return this;
  }

  @override
  RemoteRead order(String column, {bool ascending = true}) {
    _builder = _builder.order(column, ascending: ascending);
    return this;
  }

  @override
  RemoteRead limit(int count) {
    _builder = _builder.limit(count);
    return this;
  }

  @override
  Future<List<Map<String, dynamic>>> get() async {
    final result = await _builder;
    if (result == null) return [];
    return (result as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> maybeSingle() async {
    final result = await _builder.maybeSingle();
    if (result == null) return null;
    return Map<String, dynamic>.from(result as Map);
  }

  @override
  Future<Map<String, dynamic>> single() async {
    final result = await _builder.single();
    return Map<String, dynamic>.from(result as Map);
  }
}

class _MutationAdapter implements RemoteMutation {
  PostgrestFilterBuilder<dynamic> _builder;

  _MutationAdapter(this._builder);

  @override
  RemoteMutation eq(String column, dynamic value) {
    _builder = _builder.eq(column, value);
    return this;
  }

  @override
  Future<void> run() async {
    await _builder;
  }

  @override
  RemoteRead select([List<String> columns = const []]) =>
      _ReadAdapter(_builder.select(columns.isEmpty ? '*' : columns.join(',')));
}

class _StorageAdapter implements SupabaseStorageApi {
  final SupabaseStorageClient _storage;

  _StorageAdapter(this._storage);

  @override
  Future<String> upload(
    String bucket,
    String path,
    File file, {
    String cacheControl = '3600',
    bool upsert = false,
    String? contentType,
  }) async {
    await _storage.from(bucket).upload(
          path,
          file,
          fileOptions: FileOptions(
            cacheControl: cacheControl,
            upsert: upsert,
            contentType: contentType,
          ),
        );
    return path;
  }

  @override
  String getPublicUrl(String bucket, String path) =>
      _storage.from(bucket).getPublicUrl(path);

  @override
  Future<void> remove(String bucket, String path) async {
    await _storage.from(bucket).remove([path]);
  }
}