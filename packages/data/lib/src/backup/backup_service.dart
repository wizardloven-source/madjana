import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../datasources/local/local_database.dart';
import 'backup_models.dart';

/// ═══════════════════════════════════════════════════════════════
/// خدمة النسخ الاحتياطي — نسخ SQLite مباشرة مع SHA-256 للسلامة
/// ═══════════════════════════════════════════════════════════════
///
/// الاستراتيجية:
/// 1. نسخ ملف .db عبر `VACUUM INTO` — يُنتج نسخة سليمة متسقة
///    مهما كان الملف يُكتب أثناء النسخ.
/// 2. تخزين وصف JSON بجانب كل نسخة (metadata + checksum).
/// 3. تشذيب تلقائي — الاحتفاظ بآخر N نسخ فقط (gravity pruning).
class BackupService {
  /// مسار override لدليل النسخ الاحتياطي (للاختبارات والمنصات
  /// التي لا تحديد فيها مسار دعم التطبيق، كـ Windows).
  static String? _overrideBackupDir;

  /// تعيين مسار ثابت لدليل النسخ الاحتياطي (اختبار/سطح مكتب).
  static void setBackupDirectory(String path) {
    _overrideBackupDir = path;
  }

  static const _backupDirName = 'madjana_backups';
  static const _maxBackupCount = 10;
  static const _metadataExt = '.meta.json';
  static const _dbExt = '.db';

  /// مسار دليل النسخ الاحتياطي
  Future<Directory> get _backupDir async {
    final appDir = _overrideBackupDir != null
        ? Directory(_overrideBackupDir!)
        : await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, _backupDirName));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// ═══ إنشاء نسخة احتياطية ═══
  ///
  /// يستخدم `VACUUM INTO` لضمان نسخة سليمة مضغوطة
  /// بدلاً من نسخ الملف أثناء الكتابة (التي قد تُفسد).
  Future<BackupResult> createBackup({
    BackupType type = BackupType.full,
    String? farmId,
  }) async {
    final id = _generateId();
    final now = DateTime.now();
    final dir = await _backupDir;
    final dbPath = await LocalDatabase.databasePath();

    // تهيئة القاعدة إن لم تُفتح بعد (تُنشئ ملف الـ .db)
    try {
      await LocalDatabase.database;
    } catch (_) {
      return BackupResult.error('تعذّر فتح قاعدة البيانات المحلية');
    }

    // التحقق من وجود ملف القاعدة
    if (!File(dbPath).existsSync()) {
      return BackupResult.error('ملف قاعدة البيانات غير موجود: $dbPath');
    }

    final dbFile = File(dbPath);
    final backupPath = p.join(dir.path, '$id$_dbExt');
    final metaPath = p.join(dir.path, '$id$_metadataExt');

    // ═══ نسخ الملف عبر VACUUM INTO (نسخة سليمة متسقة) ═══
    // File.copy لا يُنصح به هنا لأن القاعدة قد تكون قيد الكتابة
    // أثناء النسخ. استخدام `VACUUM INTO` يضمن نسخة متسقة.
    try {
      final db = await LocalDatabase.database;
      // VACUUM INTO يتطلب SQLite 3.27.0+ (متوفر في sqflite)
      await db.execute("VACUUM INTO '$backupPath'");
    } catch (vacuumError) {
      // بديل: نسخ الملف مباشرة في حال تعذر VACUUM
      // (مخاطرة: قد يكون الملف نشطاً أثناء النسخ)
      try {
        await dbFile.copy(backupPath);
      } catch (copyError) {
        return BackupResult.error(
            'فشل النسخ الاحتياطي: ${vacuumError.toString()} (fallback: ${copyError.toString()})');
      }
    }

    // التحقق من وجود النسخة
    if (!File(backupPath).existsSync()) {
      return BackupResult.error('ملف النسخة الاحتياطية غير موجود بعد الإنشاء');
    }

    // حساب SHA-256 للسلامة
    final fileBytes = await File(backupPath).readAsBytes();
    final checksum = sha256.convert(fileBytes).toString();
    final fileSize = fileBytes.length;

    // التحقق من صحة النسخة بمحاولة فتحها
    try {
      final testDb = await openDatabase(backupPath, readOnly: true);
      // التحقق من وجود جداول البيانات
      final tables = await testDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='egg_production'",
      );
      await testDb.close();

      if (tables.isEmpty) {
        return BackupResult.error('النسخة الاحتياطية فارغة — لا تحتوي على جدول egg_production');
      }
    } catch (e) {
      return BackupResult.error('النسخة الاحتياطية تالفة: $e');
    }

    // قراءة إصدار القاعدة الأصلي
    final dbVersion = await _getDatabaseVersion();

    // إنشاء البيانات الوصفية
    final metadata = BackupMetadata(
      id: id,
      type: type,
      status: BackupStatus.success,
      createdAt: now,
      fileSizeBytes: fileSize,
      checksumSha256: checksum,
      dbVersion: dbVersion,
      farmId: farmId,
    );

    // حفظ البيانات الوصفية
    await File(metaPath).writeAsString(jsonEncode(metadata.toJson()));

    // تشذيب النسخ القديمة
    await pruneOldBackups(maxCount: _maxBackupCount);

    return BackupResult.ok(metadata);
  }

  /// ═══ استعادة نسخة احتياطية ═══
  ///
  /// ⚠️ تحذير: هذه العملية تُحلّل قاعدة البيانات الحالية بالكامل
  /// ويجب عمل نسخة احتياطية أولاً قبل الاستعادة.
  Future<RestoreResult> restoreBackup(String backupId) async {
    final dir = await _backupDir;
    final backupPath = p.join(dir.path, '$backupId$_dbExt');
    final metaPath = p.join(dir.path, '$backupId$_metadataExt');

    // التحقق من وجود الملفات
    if (!File(backupPath).existsSync()) {
      return RestoreResult.error('ملف النسخة الاحتياطية غير موجود');
    }

    // التحقق من صحة النسخة الاحتياطية بمطابقة الس checksum
    BackupMetadata? metadata;
    if (File(metaPath).existsSync()) {
      try {
        final metaJson = await File(metaPath).readAsString();
        metadata = BackupMetadata.fromJson(
            jsonDecode(metaJson) as Map<String, dynamic>);
      } catch (_) {
        // ملف الوصف تالف أو غير موجود — نكمل بدون وصف
      }
    }

    // التحقق من تطابق الس checksum للكشف عن التلف
    if (metadata != null) {
      final fileBytes = await File(backupPath).readAsBytes();
      final currentChecksum = sha256.convert(fileBytes).toString();
      if (currentChecksum != metadata.checksumSha256) {
        return RestoreResult.error(
            'النسخة الاحتياطية تالفة — الس checksum غير متطابق '
            '(متوقع: ${metadata.checksumSha256.substring(0, 16)}...، '
            'محسوب: ${currentChecksum.substring(0, 16)}...)');
      }
    }

    // التحقق من صحة قاعدة البيانات المُستعادة
    try {
      final testDb = await openDatabase(backupPath, readOnly: true);
      final tables = await testDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );
      await testDb.close();

      if (tables.isEmpty) {
        return RestoreResult.error('النسخة الاحتياطية فارغة — لا تحتوي على جداول');
      }
    } catch (e) {
      return RestoreResult.error('النسخة الاحتياطية تالفة: $e');
    }

    // ═══ استعادة قاعدة البيانات ═══
    try {
      final dbPath = await LocalDatabase.databasePath();

      // 1. نسخ الحالية كنسخة أمان قبل الاستعادة (إذا كانت موجودة)
      final safetyBackup = p.join(dir.path,
          'pre_restore_${DateTime.now().millisecondsSinceEpoch}$_dbExt');
      if (File(dbPath).existsSync()) {
        await File(dbPath).copy(safetyBackup);
      }

      // 2. نسخ النسخة الاحتياطية فوق القاعدة الحالية.
      // لا يمكن حذف الملف لأن sqflite يحتفظ بـ handle مفتوح عليه.
      // الحل: نستخدم `VACUUM FROM` أو نغلق القاعدة أولاً عبر reset().
      await LocalDatabase.reset();
      if (File(dbPath).existsSync()) {
        await File(dbPath).delete();
      }
      await File(backupPath).copy(dbPath);

      // 3. فتح القاعدة بالنسخة الجديدة للتحقق
      final restoredDb = await LocalDatabase.database;

      // عدّ السجلات المُستعادة
      final tables = [
        'egg_production', 'mortality', 'feed_consumption',
        'dispatches', 'customers', 'medications', 'payments',
      ];
      int totalRecords = 0;
      for (final table in tables) {
        try {
          final count = await restoredDb.rawQuery('SELECT COUNT(*) as c FROM $table');
          totalRecords += (count.first['c'] as int?) ?? 0;
        } catch (_) {
          // جدول غير موجود — طبيعي في بعض النسخ
        }
      }

      return RestoreResult.ok(recordsAffected: totalRecords);
    } catch (e) {
      return RestoreResult.error('فشلت الاستعادة: $e');
    }
  }

  /// ═══ سرد جميع النسخ الاحتياطية ═══
  Future<List<BackupMetadata>> listBackups() async {
    final dir = await _backupDir;
    final metaFiles = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith(_metadataExt))
        .toList();

    final backups = <BackupMetadata>[];
    for (final file in metaFiles) {
      try {
        final json = await file.readAsString();
        backups.add(
            BackupMetadata.fromJson(jsonDecode(json) as Map<String, dynamic>));
      } catch (_) {
        // ملف تالف — نتجاهله
      }
    }

    backups.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return backups;
  }

  /// ═══ تشذيب النسخ القديمة (gravity pruning) ═══
  ///
  /// يحتفظ فقط بأحدث [maxCount] نسخ ناجحة.
  /// يحذف ملفات .db + .meta.json معاً.
  Future<void> pruneOldBackups({int maxCount = _maxBackupCount}) async {
    final backups = await listBackups();
    final successful =
        backups.where((b) => b.status == BackupStatus.success).toList();

    if (successful.length <= maxCount) return;

    final toDelete = successful.sublist(maxCount);
    final dir = await _backupDir;

    for (final backup in toDelete) {
      try {
        final dbFile = File(p.join(dir.path, '${backup.id}$_dbExt'));
        final metaFile = File(p.join(dir.path, '${backup.id}$_metadataExt'));
        if (dbFile.existsSync()) await dbFile.delete();
        if (metaFile.existsSync()) await metaFile.delete();
      } catch (_) {
        // فشل الحذف — نتجاهله
      }
    }
  }

  /// ═══ حذف نسخة احتياطية ═══
  Future<void> deleteBackup(String backupId) async {
    final dir = await _backupDir;
    final dbFile = File(p.join(dir.path, '$backupId$_dbExt'));
    final metaFile = File(p.join(dir.path, '$backupId$_metadataExt'));
    if (dbFile.existsSync()) await dbFile.delete();
    if (metaFile.existsSync()) await metaFile.delete();
  }

  /// ═══ حجم جميع النسخ الاحتياطية ═══
  Future<int> totalBackupSizeBytes() async {
    final dir = await _backupDir;
    int total = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  /// ═══ مسح جميع النسخ الاحتياطية ═══
  Future<void> clearAllBackups() async {
    final dir = await _backupDir;
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// قراءة إصدار القاعدة الحالية
  Future<int> _getDatabaseVersion() async {
    final db = await LocalDatabase.database;
    final version = await db.rawQuery('PRAGMA user_version');
    return (version.first.values.first as int?) ?? 0;
  }

  /// توليد معرّف فريد للنسخة الاحتياطية
  String _generateId() {
    final now = DateTime.now();
    return 'backup_${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}_'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }
}
