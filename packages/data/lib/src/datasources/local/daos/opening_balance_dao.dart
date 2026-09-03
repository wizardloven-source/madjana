import 'dart:convert';
import 'package:core/core.dart';
import 'package:sqflite/sqflite.dart';
import '../local_database.dart';

/// DAO للأرصدة الافتتاحية للقطعان القديمة
class OpeningBalanceDao {
  static const String _table = 'opening_balances';

  Future<OpeningBalanceModel?> getForFlock(String farmId, String flockId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'farm_id = ? AND flock_id = ?',
      whereArgs: [farmId, flockId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return _fromMap(maps.first);
  }

  Future<List<OpeningBalanceModel>> getForFarm(String farmId) async {
    final db = await LocalDatabase.database;
    final maps = await db.query(
      _table,
      where: 'farm_id = ?',
      whereArgs: [farmId],
      orderBy: 'created_at DESC',
    );
    return maps.map(_fromMap).toList();
  }

  Future<void> save(OpeningBalanceModel balance) async {
    final db = await LocalDatabase.database;
    await db.insert(_table, {
      'id': balance.id,
      'farm_id': balance.farmId,
      'flock_id': balance.flockId,
      'created_at': balance.createdAt.toIso8601String(),
      'eggs_produced': balance.eggsProduced,
      'eggs_dispatched': balance.eggsDispatched,
      'feed_consumed_kg': balance.feedConsumedKg,
      'initial_birds': balance.initialBirds,
      'mortality_count': balance.mortalityCount,
      'total_payments': balance.totalPayments,
      'total_revenues': balance.totalRevenues,
      'sections': jsonEncode(balance.sections.map((s) => s.toJson()).toList()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await LocalDatabase.enqueueChange(
      tableName: _table,
      recordId: balance.id,
      action: 'INSERT',
      payload: {
        'flock_id': balance.flockId,
        'eggs_produced': balance.eggsProduced,
        'eggs_dispatched': balance.eggsDispatched,
        'feed_consumed_kg': balance.feedConsumedKg,
        'initial_birds': balance.initialBirds,
        'mortality_count': balance.mortalityCount,
        'total_payments': balance.totalPayments,
        'total_revenues': balance.totalRevenues,
        'sections': jsonEncode(balance.sections.map((s) => s.toJson()).toList()),
      },
    );
  }

  Future<void> deleteForFlock(String farmId, String flockId) async {
    final db = await LocalDatabase.database;
    await db.delete(
      _table,
      where: 'farm_id = ? AND flock_id = ?',
      whereArgs: [farmId, flockId],
    );
  }

  OpeningBalanceModel _fromMap(Map<String, dynamic> map) {
    final sectionsRaw = map['sections'] as String?;
    List<OpeningSectionModel> sections = const [];
    if (sectionsRaw != null && sectionsRaw.isNotEmpty) {
      try {
        sections = (jsonDecode(sectionsRaw) as List)
            .map((e) => OpeningSectionModel.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {
        sections = const [];
      }
    }
    return OpeningBalanceModel(
      id: map['id'] as String,
      farmId: map['farm_id'] as String,
      flockId: map['flock_id'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      eggsProduced: map['eggs_produced'] as int? ?? 0,
      eggsDispatched: map['eggs_dispatched'] as int? ?? 0,
      feedConsumedKg: (map['feed_consumed_kg'] as num?)?.toDouble() ?? 0,
      initialBirds: map['initial_birds'] as int? ?? 0,
      mortalityCount: map['mortality_count'] as int? ?? 0,
      totalPayments: (map['total_payments'] as num?)?.toDouble() ?? 0,
      totalRevenues: (map['total_revenues'] as num?)?.toDouble() ?? 0,
      sections: sections,
    );
  }
}