import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty
      ? args.first
      : r'C:\Users\MTC\AppData\Roaming\madjana\poultry_farm.db';
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(path);
  try {
    Future<void> pr(String title, String sql) async {
      print('\n=== $title ===');
      try {
        final rows = await db.rawQuery(sql);
        print('count=${rows.length}');
        for (final r in rows) {
          print(r);
        }
      } catch (e) {
        print('ERR: $e');
      }
    }

    await pr('CUSTOMERS sampler (سامر or others)',
        "SELECT id, name, phone, farm_id, total_debt, is_global, sync_status, version, deleted_at FROM customers WHERE name LIKE '%سامر%' OR name LIKE '%عربش%' OR name LIKE '%سامح%'");
    await pr('CUSTOMERS all (summary)',
        'SELECT id, name, farm_id, is_global, sync_status FROM customers ORDER BY name');
    await pr('EGG_DISPATCH flock join diagnostics',
        'SELECT id, flock_id, customer_id, date, cartons, trays, total_eggs FROM egg_dispatch ORDER BY date DESC LIMIT 15');
    await pr('EGG_DISPATCH flock_id null count',
        'SELECT COUNT(*) AS total, SUM(CASE WHEN flock_id IS NULL OR flock_id='' THEN 1 ELSE 0 END) AS missing_flock FROM egg_dispatch');
    await pr('OPENING_BALANCES',
        'SELECT id, farm_id, flock_id, eggs_produced, mortality_count, created_at FROM opening_balances ORDER BY created_at DESC');
    await pr('MORTALITY sample dates',
        'SELECT date, COUNT(*) c FROM mortality GROUP BY date ORDER BY date DESC LIMIT 10');
    await pr('FEED_RECEIVED modes',
        'SELECT mode, COUNT(*) c FROM feed_received GROUP BY mode');
    await pr('INVENTORY_ITEMS',
        'SELECT id, name, unit, quantity, low_stock_threshold FROM inventory_items ORDER BY name');
  } finally {
    await db.close();
  }
  exit(0);
}