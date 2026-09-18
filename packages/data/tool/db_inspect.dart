import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main() async {
  sqfliteFfiInit();
  final path = r'C:\Users\MTC\Desktop\madjana\.dart_tool\sqflite_common_ffi\databases\poultry_farm.db';
  if (!File(path).existsSync()) {
    stdout.writeln('DB NOT FOUND');
    return;
  }
  final db = await databaseFactoryFfi.openDatabase(path);

  Future<void> dumpTable(String name, List<String> cols) async {
    final rows = await db.query(name);
    stdout.writeln('=== $name (${rows.length}) ===');
    for (final r in rows.take(60)) {
      final vals = cols.map((c) => '$c=${r[c]}').join(' | ');
      stdout.writeln('  $vals');
    }
    stdout.writeln();
  }

  final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
  stdout.writeln('=== TABLES (${tables.length}) ===');
  for (final t in tables) {
    stdout.writeln('  ${t['name']}');
  }
  stdout.writeln();

  for (final t in tables) {
    final name = t['name'] as String;
    if (name.startsWith('sqlite_')) continue;
    final count = (await db.rawQuery('SELECT COUNT(*) AS c FROM $name')).first['c'];
    stdout.writeln('$name: $count rows');
  }
  stdout.writeln();
  await db.close();
}