import 'dart:io';

import 'package:data/src/datasources/local/local_database.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/db_harness.dart';

void main() {
  setUpAll(enableFfiDatabase);

  late Directory dbDir;

  setUp(() async {
    dbDir = await createDbHarness('device_id');
  });

  tearDown(() => tearDownDbHarness(dbDir));

  // P0-003 regression: getDeviceId generates and persists a device UUID
  group('LocalDatabase.getDeviceId — P0-003 regression', () {
    test('يولّد UUID بتنسيق صحيح', () async {
      final id = await LocalDatabase.getDeviceId();
      final uuidRegex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(uuidRegex.hasMatch(id), true,
          reason: 'getDeviceId أعاد "$id" وهو ليس UUID v4 صالح');
    });

    test('يُعيد نفس المعرّف عند الاستدعاءات المتكررة', () async {
      final id1 = await LocalDatabase.getDeviceId();
      final id2 = await LocalDatabase.getDeviceId();
      expect(id1, id2,
          reason: 'getDeviceId يجب أن يُعيد نفس القيمة في كل مرة');
    });

    test('يُخزّن المعرّف في app_settings以便 الاسترجاع لاحقاً', () async {
      final id = await LocalDatabase.getDeviceId();
      final db = await LocalDatabase.database;
      final rows = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['device_id'],
        limit: 1,
      );
      expect(rows, isNotEmpty, reason: 'المعرّف غير مخزّن في app_settings');
      expect(rows.first['value'], id,
          reason: 'القيمة المخزّنة لا تتطابق مع المعرّف المُعاد');
    });

    test('يُعيد المعرّف المخزّن بعد إعادة تشغيل قاعدة البيانات', () async {
      final id1 = await LocalDatabase.getDeviceId();
      // إعادة تهيئة قاعدة البيانات (محاكاة إعادة تشغيل التطبيق)
      await LocalDatabase.close();
      final id2 = await LocalDatabase.getDeviceId();
      expect(id1, id2,
          reason: 'المعرّف يجب أن يبقى ثابتاً بعد إعادة تشغيل قاعدة البيانات');
    });
  });
}
