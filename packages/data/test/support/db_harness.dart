import 'dart:io';

import 'package:data/src/datasources/local/local_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// يفعّل محرك SQLite عبر FFI (بديل يحاكي sqflite على جهاز المضيف).
void enableFfiDatabase() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

/// يُنشئ قاعدة بيانات محلية جديدة في مجلد مؤقت ويعنيّنها كمسار LocalDatabase.
/// يُرجع المجلد لإزالته في نهاية الاختبار.
Future<Directory> createDbHarness(String label) async {
  final dir = await Directory.systemTemp.createTemp('madjana_${label}_');
  final path = '${dir.path}${Platform.pathSeparator}poultry_farm.db';
  await LocalDatabase.close();
  LocalDatabase.setDatabasePath(path);
  return dir;
}

/// إغلاق القاعدة وإزالة المجلد المؤقت.
Future<void> tearDownDbHarness(Directory dir) async {
  await LocalDatabase.close();
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
}