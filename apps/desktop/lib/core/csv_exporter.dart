import 'dart:convert';
import 'dart:io';

import 'package:data/data.dart';
import 'package:path/path.dart' as p;

/// أداة تصدير البيانات إلى ملفات CSV (تفتح في Excel)
class CsvExporter {
  CsvExporter._();

  /// حفظ صفوف CSV في مجلد madjana_exports بجانب قاعدة البيانات
  ///
  /// [rows]: كل عنصر يمثل صفاً؛ العنصر الأول هو رؤوس الأعمدة.
  /// يعيد مسار الملف المحفوظ.
  static Future<String> saveCsv({
    required String fileName,
    required List<List<String>> rows,
  }) async {
    if (rows.isEmpty) {
      throw Exception('لا توجد بيانات للتصدير');
    }

    final dbPath = await LocalDatabase.databasePath();
    final dir = Directory(p.join(p.dirname(dbPath), 'madjana_exports'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final filePath = p.join(dir.path, '$fileName.csv');
    final file = File(filePath);

    final buffer = StringBuffer();
    // BOM لدعم العربية عند الفتح في Excel
    buffer.write('\uFEFF');
    for (final row in rows) {
      buffer.write(row.map(_escape).join(','));
      buffer.writeln();
    }
    await file.writeAsBytes(utf8.encode(buffer.toString()));
    return filePath;
  }

  static String _escape(String cell) {
    if (cell.contains(',') || cell.contains('"') || cell.contains('\n')) {
      return '"${cell.replaceAll('"', '""')}"';
    }
    return cell;
  }
}
