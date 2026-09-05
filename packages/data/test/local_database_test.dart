import 'dart:convert';
import 'dart:io';

import 'package:data/src/datasources/local/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_harness.dart';

void main() {
  setUpAll(enableFfiDatabase);

  late Directory dbDir;

  setUp(() async {
    dbDir = await createDbHarness('local_db');
  });

  tearDown(() => tearDownDbHarness(dbDir));

  group('LocalDatabase - _onCreate (v19)', () {
    test('ينشئ جميع الجداول الأساسية', () async {
      final db = await LocalDatabase.database;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
      );
      final names = tables.map((r) => r['name']).toSet();

      const expected = {
        'egg_production', 'mortality', 'feed_consumption', 'egg_dispatch',
        'feed_received', 'medications', 'customers', 'medicines_catalog',
        'flocks', 'users', 'payments', 'expenses', 'inventory_items',
        'inventory_transactions', 'app_settings', 'sync_queue', 'sync_history',
        'sync_state', 'session', 'worker_notes', 'worker_reminders',
        'dispatch_requests', 'opening_balances', 'conflicts',
      };
      for (final t in expected) {
        expect(names, contains(t), reason: 'الجدول $t مفقود من المخطط');
      }
    });

    test('عمود version موجود على كل الجداول المنسقة (OCC)', () async {
      final db = await LocalDatabase.database;
      const versionedTables = {
        'egg_production', 'mortality', 'feed_consumption', 'feed_received',
        'egg_dispatch', 'medications', 'customers', 'flocks', 'expenses',
        'payments', 'inventory_items',
      };
      for (final t in versionedTables) {
        final cols = await db.rawQuery('PRAGMA table_info($t)');
        expect(
          cols.map((c) => c['name']),
          contains('version'),
          reason: 'الجدول $t يفتقر لعمود version',
        );
      }
    });

    test('sync_queue يحتوي أعمدة إعادة المحاولة والمُعاملات', () async {
      final db = await LocalDatabase.database;
      final cols = (await db.rawQuery('PRAGMA table_info(sync_queue)'))
          .map((c) => c['name'])
          .toList();
      for (final col in [
        'operation_id', 'attempts', 'last_error', 'last_error_code',
        'next_retry_at', 'status',
      ]) {
        expect(cols, contains(col));
      }
    });

    test('الفهارس التشغيلية تُنشأ', () async {
      final db = await LocalDatabase.database;
      final idx = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      );
      final names = idx.map((r) => r['name']).toSet();
      expect(names, contains('idx_egg_production_farm_date'));
      expect(names, contains('idx_sync_queue_status'));
      expect(names, contains('idx_inventory_items_farm'));
    });
  });

  group('LocalDatabase._onUpgrade - self-heal (v19 على مخطط مكتمل)', () {
    test('إعادة تشغيل كل ترقيات v1..v19 على مخطط كامل لا ينهار', () async {
      // 1) بناء مخطط كامل v19 (بما فيها الجداول الأساسية)
      await LocalDatabase.database;

      // 2) خفض user_version يدويًا ثم فتح من جديد —
      //    يحاكي ترقية فُطرت في منتصفها بعد مخطط مكتمل.
      final path = await LocalDatabase.databasePath();
      final conn = await databaseFactory.openDatabase(path);
      await conn.rawQuery('PRAGMA user_version = 1');
      await conn.close();

      // 3) إعادة فتح عبر LocalDatabase → تُشغّل _onUpgrade(1 → 19)
      await LocalDatabase.close();
      final reopened = await LocalDatabase.database;
      expect(reopened.isOpen, isTrue);

      // التأكد أن المخطط ما زال سليمًا بعد الترقية المكررة
      final versioned = ['payments', 'expenses', 'inventory_items'];
      for (final t in versioned) {
        final cols = await reopened.rawQuery('PRAGMA table_info($t)');
        expect(
          cols.map((c) => c['name']),
          contains('version'),
          reason: 'فقد عمود version في $t بعد self-heal',
        );
      }
    });
  });

  group('جسر قاعدة المزامنة (enqueueChange)', () {
    test('يُسجّل INSERT في sync_queue مع payload نظيف و operation_id مستقل',
        () async {
      final db = await LocalDatabase.database;
      await db.insert('session', {
        'id': 1,
        'user_id': 'user-1',
        'farm_id': 'farm-1',
      });

      await LocalDatabase.enqueueChange(
        tableName: 'egg_production',
        recordId: 'rec-1',
        action: 'INSERT',
        payload: {
          'id': 'rec-1',
          'farm_id': 'farm-1',
          'version': 4,
          'sync_status': 'pending',
          'deleted_at': null,
          'created_at': '2026-01-01T00:00:00.000',
          'updated_at': '2026-01-01T00:00:00.000',
          'flock_id': 'flock-1',
          'cartons': 2,
        },
      );

      final rows = await db.query(
        'sync_queue',
        where: 'record_id = ?',
        whereArgs: ['rec-1'],
      );
      expect(rows, hasLength(1));
      final row = rows.first;

      // operation_id مستقل ومعرّف العملية مخزن في sync_queue
      expect(row['operation_id'], isNotNull);
      expect(row['operation_id'] as String, isNotEmpty);
      expect(row['operation_id'] as String, isNot('rec-1'));

      // action والجلسة
      expect(row['action'], 'INSERT');
      expect(row['user_id'], 'user-1');
      expect(row['status'], 'pending');

      // payload نظيف بدون أعمدة نظامية
      final payload =
          jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      const systemCols = {
        'id', 'farm_id', 'version', 'sync_status', 'deleted_at',
        'created_at', 'updated_at',
      };
      for (final c in systemCols) {
        expect(payload.containsKey(c), isFalse, reason: 'payload يحوي $c');
      }
      expect(payload['flock_id'], 'flock-1');
      expect(payload['cartons'], 2);
    });

    test('UPDATE/DELETE يحمل previous_version في الـ payload', () async {
      final db = await LocalDatabase.database;

      await LocalDatabase.enqueueChange(
        tableName: 'payments',
        recordId: 'pay-1',
        action: 'UPDATE',
        previousVersion: 3,
        payload: {'amount_paid': 500.0},
      );
      await LocalDatabase.enqueueChange(
        tableName: 'payments',
        recordId: 'pay-1',
        action: 'DELETE',
        previousVersion: 3,
        payload: {'id': 'pay-1'},
      );

      final rows = await db.query(
        'sync_queue',
        where: 'record_id = ?',
        whereArgs: ['pay-1'],
        orderBy: 'created_at ASC',
      );
      expect(rows, hasLength(2));
      final updatePayload =
          jsonDecode(rows[0]['payload'] as String) as Map<String, dynamic>;
      final deletePayload =
          jsonDecode(rows[1]['payload'] as String) as Map<String, dynamic>;

      expect(updatePayload['previous_version'], 3);
      expect(deletePayload['previous_version'], 3);
    });
  });

  group('LocalDatabase - أدوات التشغيل', () {
    test('clearAll يفرّغ جميع الجداول التشغيلية', () async {
      final db = await LocalDatabase.database;
      await db.insert('flocks', {
        'id': 'flock-1',
        'farm_id': 'farm-1',
        'breed': 'لوهمان',
        'start_date': '2026-01-01',
        'initial_count': 100,
        'current_count': 100,
      });
      await LocalDatabase.enqueueChange(
        tableName: 'flocks',
        recordId: 'flock-1',
        action: 'INSERT',
        payload: {'breed': 'لوهمان'},
      );

      await LocalDatabase.clearAll();

      expect(await db.query('flocks'), isEmpty);
      expect(await db.query('sync_queue'), isEmpty);
      expect(await db.query('session'), isEmpty);
    });

    test('runIntegrityCheck يعيد true لقاعدة سليمة', () async {
      final db = await LocalDatabase.database;
      await db.insert('app_settings', {'key': 'k', 'value': 'v'});
      expect(await LocalDatabase.runIntegrityCheck(), isTrue);
    });

    test('backupDatabase يُنشئ نسخة احتياطية من ملف القاعدة', () async {
      await LocalDatabase.database;
      final backupPath = await LocalDatabase.backupDatabase();
      expect(backupPath, isNotNull);
      expect(File(backupPath!).existsSync(), isTrue);
      expect(backupPath, endsWith('.db'));
    });
  });
}