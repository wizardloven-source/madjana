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

    await pr('PAYMENTS rows (latest first)',
        'SELECT * FROM payments ORDER BY created_at DESC LIMIT 10');
    await pr('SYNC_QUEUE payments ops',
        "SELECT * FROM sync_queue WHERE table_name='payments' ORDER BY created_at DESC LIMIT 10");
    await pr('SYNC_QUEUE all ops (latest)',
        'SELECT * FROM sync_queue ORDER BY created_at DESC LIMIT 20');
    await pr('EGG_DISPATCH latest',
        "SELECT id, date, cartons, total_eggs, payment_status, sync_status, version, worker_id FROM egg_dispatch ORDER BY created_at DESC LIMIT 5");
    await pr('SESSION current',
        'SELECT id, user_id, farm_id, last_login FROM session LIMIT 2');
    await pr('SYNC_STATE',
        'SELECT * FROM sync_state');
  } finally {
    await db.close();
  }
  exit(0);
}