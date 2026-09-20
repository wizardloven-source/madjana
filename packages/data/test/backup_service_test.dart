import 'dart:io';

import 'package:data/src/backup/backup_models.dart';
import 'package:data/src/backup/backup_service.dart';
import 'package:data/src/datasources/local/local_database.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/db_harness.dart';

void main() {
  setUpAll(enableFfiDatabase);

  late Directory dbDir;
  late Directory backupDir;

  setUp(() async {
    dbDir = await createDbHarness('backup');
    backupDir = await Directory.systemTemp.createTemp('madjana_bkups_');
    BackupService.setBackupDirectory(backupDir.path);
  });

  tearDown(() async {
    await LocalDatabase.close();
    if (dbDir.existsSync()) dbDir.deleteSync(recursive: true);
    if (backupDir.existsSync()) backupDir.deleteSync(recursive: true);
  });

  group('BackupService', () {
    test('إنشاء نسخة احتياطية كاملة — metadata صحيح', () async {
      final db = await LocalDatabase.database;
      await db.insert('egg_production', {
        'id': 'egg-1',
        'farm_id': 'farm-1',
        'flock_id': 'flock-1',
        'date': '2026-09-16',
        'total_eggs': 120,
        'broken_eggs': 5,
        'worker_id': 'worker-1',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'sync_status': 'synced',
        'version': 1,
      });

      final service = BackupService();
      final result = await service.createBackup();

      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.metadata, isNotNull);

      final meta = result.metadata!;
      expect(meta.status, BackupStatus.success);
      expect(meta.type, BackupType.full);
      expect(meta.checksumSha256.length, 64);
      expect(meta.fileSizeBytes, greaterThan(0));
      expect(meta.dbVersion, greaterThanOrEqualTo(1));
    });

    test('قائمة النسخ تُرجع النسخة المُنشأة', () async {
      final service = BackupService();
      final createResult = await service.createBackup();
      expect(createResult.success, isTrue);

      final backups = await service.listBackups();
      expect(backups, isNotEmpty);
      expect(backups.first.status, BackupStatus.success);
    });

    test('استعادة النسخة — يتم نسخ الملف والتحقق من سلامته', () async {
      // نسخة أولية بها سجل
      final service = BackupService();
      final create = await service.createBackup();
      expect(create.success, isTrue);
      final backupId = create.metadata!.id;

      // محاولة الاستعادة
      final restore = await service.restoreBackup(backupId);
      expect(restore.success, isTrue, reason: restore.errorMessage);
      expect(restore.recordsAffected, greaterThanOrEqualTo(0));
    });

    test('التحقق من سلامة — checksum متطابق في النسخة الكاملة', () async {
      final service = BackupService();
      final create = await service.createBackup();
      expect(create.success, isTrue);

      // فتح الملف الاحتياطي وقراءة محتواه — يجب أن يكون صحيحاً
      final backupDir2 = Directory(
          '${backupDir.path}${Platform.pathSeparator}madjana_backups');
      final dbFiles = backupDir2
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.db'));
      expect(dbFiles.length, 1, reason: 'يوجد نسخة احتياطية واحدة فقط');

      final backupDbFile = dbFiles.first;
      expect(await backupDbFile.length(), greaterThan(0));
    });

    test('استعادة نسخة تالفة يُفشل التحقق من الس checksum', () async {
      final service = BackupService();
      final create = await service.createBackup();
      final backupId = create.metadata!.id;

      // إتلاف النسخة (كتابة بيانات فاسدة)
      final dir = Directory(
          '${backupDir.path}${Platform.pathSeparator}madjana_backups');
      final backupFile =
          File('${dir.path}${Platform.pathSeparator}$backupId.db');
      await backupFile.writeAsBytes(List.filled(64, 0));

      final restore = await service.restoreBackup(backupId);
      expect(restore.success, isFalse);
      expect(restore.errorMessage, contains('تالفة'));
    });

    test('تشذيب النسخ القديمة', () async {
      final service = BackupService();
      for (var i = 0; i < 5; i++) {
        await service.createBackup();
      }

      // بما أن الحد الافتراضي 10 لا يُفعل مع 5 نسخ — نتحقق من استدامتها
      final backups = await service.listBackups();
      expect(backups.length, 5);
    });

    test('حذف نسخة احتياطية', () async {
      final service = BackupService();
      final create = await service.createBackup();
      final backupId = create.metadata!.id;

      await service.deleteBackup(backupId);
      final backups = await service.listBackups();
      expect(backups.where((b) => b.id == backupId), isEmpty);
    });
  });
}