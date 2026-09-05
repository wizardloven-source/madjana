import 'dart:convert';
import 'dart:io';
import 'package:data/src/datasources/remote/supabase_api.dart';

/// تنفيذ مزيّف لطبقة Supabase يُنفّذ الجداول والمرشّحات وRPC في الذاكرة،
/// ويُسجّل كل عملية في [calls] لإثبات العقود في الاختبارات.
class FakeSupabaseApi implements SupabaseApi {
  final Map<String, List<Map<String, dynamic>>> tables = {};
  final List<String> calls = [];
  final Map<String, Map<String, File>> storageFiles = {};

  int _idCounter = 0;

  /// محاكاة استجابة دالة RPC (تُرجع null افتراضياً).
  dynamic Function(String name, Map<String, dynamic> params)? onRpc;

  /// هل يرمي خطأً في عمليات الكتابة?
  bool failWrites = false;

  /// هل يرمي خطأً في عمليات القراءة (محاكاة انقطاع الاتصال)?
  bool failReads = false;

  /// هل يرمي خطأً في عمليات Storage (اختبار تحويل الخطأ)?
  bool failStorage = false;

  void seed(String table, Iterable<Map<String, dynamic>> rows) {
    tables.putIfAbsent(table, () => []).addAll(rows);
  }

  void clearCalls() => calls.clear();

  bool findCall(String partial) => calls.any((c) => c.contains(partial));

  String get lastCall => calls.isEmpty ? '' : calls.last;

  @override
  RemoteTable from(String table) => _FakeTable(this, table);

  @override
  Future<dynamic> rpc(String name, {Map<String, dynamic>? params}) async {
    final p = params ?? const <String, dynamic>{};
    calls.add('rpc $name ${jsonEncode(p)}');
    return onRpc?.call(name, p);
  }

  @override
  SupabaseStorageApi get storage => _FakeStorage(this);
}

class _FakeTable implements RemoteTable {
  final FakeSupabaseApi _api;
  final String _table;

  _FakeTable(this._api, this._table);

  @override
  RemoteRead select({List<String> columns = const []}) =>
      _FakeRead(_api, _table, columns);

  @override
  RemoteMutation insert(Object values, {String? onConflict}) =>
      _FakeMutation(_api, _table, 'insert', values, onConflict);

  @override
  RemoteMutation upsert(Object values, {String? onConflict}) =>
      _FakeMutation(_api, _table, 'upsert', values, onConflict);

  @override
  RemoteMutation update(Map<String, dynamic> values) =>
      _FakeMutation(_api, _table, 'update', values);

  @override
  RemoteMutation delete() => _FakeMutation(_api, _table, 'delete');
}

class _FakeRead implements RemoteRead {
  final FakeSupabaseApi _api;
  final String _table;
  final List<String> _columns;
  final List<(String, String, dynamic)> _filters = [];
  final List<Map<String, dynamic>>? _baseRows;

  String? _order;
  bool _asc = true;
  int? _limit;

  _FakeRead(this._api, this._table, this._columns) : _baseRows = null;

  _FakeRead.pending(this._api, this._table, this._columns, this._baseRows);

  @override
  RemoteRead eq(String column, dynamic value) {
    _filters.add(('eq', column, value));
    return this;
  }

  @override
  RemoteRead gte(String column, dynamic value) {
    _filters.add(('gte', column, value));
    return this;
  }

  @override
  RemoteRead lte(String column, dynamic value) {
    _filters.add(('lte', column, value));
    return this;
  }

  @override
  RemoteRead order(String column, {bool ascending = true}) {
    _order = column;
    _asc = ascending;
    return this;
  }

  @override
  RemoteRead limit(int count) {
    _limit = count;
    return this;
  }

  @override
  Future<List<Map<String, dynamic>>> get() async {
    _throwIfReadFails();
    final rows = _queryRows();
    _logRead();
    return rows;
  }

  @override
  Future<Map<String, dynamic>?> maybeSingle() async {
    _throwIfReadFails();
    final rows = _queryRows();
    _logRead();
    return rows.isEmpty ? null : rows.first;
  }

  @override
  Future<Map<String, dynamic>> single() async {
    _throwIfReadFails();
    final rows = _queryRows();
    _logRead();
    if (rows.isEmpty) {
      throw StateError('fake: empty result for single() on $_table');
    }
    return rows.first;
  }

  bool _logged = false;

  void _throwIfReadFails() {
    if (_api.failReads) throw StateError('fake read failure');
  }

  void _logRead() {
    if (_logged) return;
    _logged = true;
    final entry = 'select $_table ${_columns.join(',')}';
    if (!_api.calls.contains(entry)) _api.calls.insert(0, entry);
    for (final f in _filters) {
      _api.calls.add('${f.$1} ${f.$2}=${f.$3}');
    }
    if (_order != null) _api.calls.add('order $_table $_order asc=$_asc');
    if (_limit != null) _api.calls.add('limit $_table $_limit');
  }

  List<Map<String, dynamic>> _queryRows() {
    var rows = _baseRows ?? _api.tables[_table] ?? const <Map<String, dynamic>>[];
    rows = rows.where(_matchesFilters).toList();

    if (_columns.isNotEmpty) {
      rows = rows
          .map((r) => {
                for (final c in _columns)
                  if (r.containsKey(c)) c: r[c]
              })
          .toList();
    }

    if (_baseRows != null) return rows;

    if (_order != null) {
      rows = [...rows]..sort((a, b) {
          final av = a[_order];
          final bv = b[_order];
          final an = av is num ? av : num.tryParse('$av');
          final bn = bv is num ? bv : num.tryParse('$bv');
          final c = (an != null && bn != null)
              ? an.compareTo(bn)
              : '$av'.compareTo('$bv');
          return _asc ? c : -c;
        });
    }
    if (_limit != null && rows.length > _limit!) {
      rows = rows.sublist(0, _limit);
    }
    return rows;
  }

  bool _matchesFilters(Map<String, dynamic> row) =>
      _filters.every((f) => _matchesCell(row[f.$2], f.$1, f.$3));

  bool _matchesCell(dynamic actual, String op, dynamic expected) {
    switch (op) {
      case 'eq':
        return actual == expected;
      case 'gte':
        return _compare(actual, expected) >= 0;
      case 'lte':
        return _compare(actual, expected) <= 0;
    }
    return false;
  }

  int _compare(dynamic a, dynamic b) {
    final na = a is num ? a : num.tryParse('$a');
    final nb = b is num ? b : num.tryParse('$b');
    if (na != null && nb != null) return na.compareTo(nb);
    return '$a'.compareTo('$b');
  }
}

class _FakeMutation implements RemoteMutation {
  final FakeSupabaseApi _api;
  final String _table;
  final String _op;
  final Object? _values;
  final String? _onConflict;
  final List<(String, String, dynamic)> _filters = [];

  bool _applied = false;
  List<Map<String, dynamic>>? _resultRows;

  _FakeMutation(this._api, this._table, this._op, [this._values, this._onConflict]);

  @override
  RemoteMutation eq(String column, dynamic value) {
    _filters.add(('eq', column, value));
    return this;
  }

  @override
  Future<void> run() async {
    _applyNow();
  }

  @override
  RemoteRead select([List<String> columns = const []]) {
    _applyNow();
    return _FakeRead.pending(_api, _table, columns, _resultRows);
  }

  void _applyNow() {
    if (_applied) return;
    _applied = true;
    if (_api.failWrites) throw Exception('fake write failure');

    final rows = _api.tables.putIfAbsent(_table, () => []);
    final values = _values is List ? _values as List : [_values];

    switch (_op) {
      case 'insert':
        for (final v in values) {
          final row = Map<String, dynamic>.from(v as Map<String, dynamic>);
          row.putIfAbsent('id', () => 'id-${++_api._idCounter}');
          rows.add(row);
        }
        _resultRows = rows.sublist(rows.length - values.length);
        _api.calls.add('insert $_table ${jsonEncode(values)}');
      case 'upsert':
        for (final v in values) {
          final row = Map<String, dynamic>.from(v as Map<String, dynamic>);
          row.putIfAbsent('id', () => 'id-${++_api._idCounter}');
          final key = _onConflict ?? 'id';
          final idx = rows.indexWhere((r) => r[key] == row[key]);
          if (idx >= 0) {
            rows[idx] = row;
          } else {
            rows.add(row);
          }
        }
        _resultRows = rows.sublist(rows.length - values.length);
        _api.calls.add('upsert $_table ${jsonEncode(values)} onConflict=$_onConflict');
      case 'update':
        final matches = rows.where(_matchesFilters).toList();
        for (final r in matches) {
          r.addAll(_values as Map<String, dynamic>);
        }
        _api.calls.add('update $_table ${jsonEncode(_values)} $_filtersLabel');
      case 'delete':
        rows.removeWhere(_matchesFilters);
        _api.calls.add('delete $_table $_filtersLabel');
    }
  }

  String get _filtersLabel =>
      _filters.map((f) => '${f.$1} ${f.$2}=${f.$3}').join(' ');

  bool _matchesFilters(Map<String, dynamic> row) =>
      _filters.every((f) => row[f.$2] == f.$3);
}

class _FakeStorage implements SupabaseStorageApi {
  final FakeSupabaseApi _api;

  _FakeStorage(this._api);

  @override
  Future<String> upload(
    String bucket,
    String path,
    File file, {
    String cacheControl = '3600',
    bool upsert = false,
    String? contentType,
  }) async {
    if (_api.failStorage) throw Exception('storage down');
    _api.storageFiles.putIfAbsent(bucket, () => {})[path] = file;
    _api.calls.add('storage upload $bucket $path content=$contentType');
    return path;
  }

  @override
  String getPublicUrl(String bucket, String path) {
    _api.calls.add('storage getPublicUrl $bucket $path');
    return 'https://fake.storage.example/$bucket/$path';
  }

  @override
  Future<void> remove(String bucket, String path) async {
    if (_api.failStorage) throw Exception('storage down');
    _api.storageFiles.putIfAbsent(bucket, () => {}).remove(path);
    _api.calls.add('storage remove $bucket $path');
  }
}